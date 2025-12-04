const fs = require("fs");
const os = require("os");
const path = require("path");
const { promisify } = require("util");
const { SecretsManagerClient, GetSecretValueCommand } = require("@aws-sdk/client-secrets-manager");
const { S3Client, GetObjectCommand, PutObjectCommand } = require("@aws-sdk/client-s3");
const SFTPClient = require("ssh2-sftp-client");

const chmod = promisify(fs.chmod);

const secretsClient = new SecretsManagerClient();
const s3Client = new S3Client({});

const logger = console; // simple logging

async function getConfig() {
    const secretName = process.env.CONFIG_SECRET_NAME;
    if (!secretName) {
        throw new Error("CONFIG_SECRET_NAME environment variable is not set");
    }

    const cmd = new GetSecretValueCommand({ SecretId: secretName });
    const resp = await secretsClient.send(cmd);

    let secretString;
    if (resp.SecretString) {
        secretString = resp.SecretString;
    } else if (resp.SecretBinary) {
        secretString = Buffer.from(resp.SecretBinary, "base64").toString("utf-8");
    } else {
        throw new Error("Secret has no SecretString or SecretBinary");
    }

    const config = JSON.parse(secretString);
    return config;
}

async function downloadPrivateKey(config) {
    const bucket = config["LOG_FETCH_PRIVATE_KEY_S3_BUCKET"];
    const key = config["LOG_FETCH_PRIVATE_KEY_S3_KEY"];

    if (!bucket || !key) {
        throw new Error("LOG_FETCH_PRIVATE_KEY_S3_BUCKET or LOG_FETCH_PRIVATE_KEY_S3_KEY missing in config");
    }

    const localPath = path.join(os.tmpdir(), "ssh_key");
    logger.info(`Downloading private key from s3://${bucket}/${key} to ${localPath}`);

    const cmd = new GetObjectCommand({
        Bucket: bucket,
        Key: key,
    });

    const resp = await s3Client.send(cmd);

    // resp.Body is a stream
    await new Promise((resolve, reject) => {
        const writeStream = fs.createWriteStream(localPath);
        resp.Body.pipe(writeStream);
        resp.Body.on("error", reject);
        writeStream.on("finish", resolve);
        writeStream.on("error", reject);
    });

    await chmod(localPath, 0o600);

    return localPath;
}

function buildRemoteLogPath(config) {
    const dayOffset = parseInt(config["LOG_FETCH_DAY_OFFSET"] || "1", 10);
    const dateFormat = config["LOG_FETCH_DATE_FORMAT"] || "%Y-%m-%d";

    const now = new Date();
    const targetDate = new Date(now.getTime() - dayOffset * 24 * 60 * 60 * 1000);

    // We only support %Y-%m-%d for now; if you need more formats, we can extend
    let dateStr;
    if (dateFormat === "%Y-%m-%d") {
        const yyyy = targetDate.getUTCFullYear();
        const mm = String(targetDate.getUTCMonth() + 1).padStart(2, "0");
        const dd = String(targetDate.getUTCDate()).padStart(2, "0");
        dateStr = `${yyyy}-${mm}-${dd}`;
    } else {
        // cheap fallback: ISO date prefix
        dateStr = targetDate.toISOString().slice(0, 10);
    }

    const template = config["LOG_FETCH_REMOTE_LOG_TEMPLATE"]; // e.g. "access.log-{date}.gz"
    if (!template) {
        throw new Error("LOG_FETCH_REMOTE_LOG_TEMPLATE missing in config");
    }

    const filename = template.replace("{date}", dateStr);

    let remoteDir = config["LOG_FETCH_REMOTE_LOG_DIR"] || "";
    if (remoteDir && !remoteDir.endsWith("/")) {
        remoteDir += "/";
    }

    const remotePath = remoteDir + filename;

    // canonical YYYY-MM-DD for S3 partitioning
    const s3Date = dateStr;
    return { remotePath, filename, s3Date };
}

async function fetchRemoteLog(config, keyPath, remotePath, localPath) {
    const host = config["LOG_FETCH_SSH_HOST"];
    const user = config["LOG_FETCH_SSH_USER"];
    const port = parseInt(config["LOG_FETCH_SSH_PORT"] || "22", 10);

    if (!host || !user) {
        throw new Error("LOG_FETCH_SSH_HOST or LOG_FETCH_SSH_USER missing in config");
    }

    logger.info(`Connecting via SFTP to ${user}@${host}:${port}`);
    logger.info(`Remote path: ${remotePath}`);
    logger.info(`Local path: ${localPath}`);

    const sftp = new SFTPClient();

    try {
        await sftp.connect({
            host,
            port,
            username: user,
            privateKey: fs.readFileSync(keyPath),
            // optional: strict host key checking can be configured here if needed
        });

        await sftp.fastGet(remotePath, localPath);
        logger.info("Successfully fetched remote log file via SFTP.");
    } catch (err) {
        logger.error("SFTP error:", err);
        throw err;
    } finally {
        try {
            await sftp.end();
        } catch (_) {
            // ignore
        }
    }
}

async function uploadToS3(config, localPath, filename, s3Date) {
    const rawBucket = config["LOG_FETCH_RAW_BUCKET"];
    if (!rawBucket) {
        throw new Error("LOG_FETCH_RAW_BUCKET missing in config");
    }

    const s3Key = `raw/date=${s3Date}/${filename}`;
    logger.info(`Uploading ${localPath} to s3://${rawBucket}/${s3Key}`);

    const body = fs.createReadStream(localPath);

    const cmd = new PutObjectCommand({
        Bucket: rawBucket,
        Key: s3Key,
        Body: body,
    });

    await s3Client.send(cmd);

    return {
        bucket: rawBucket,
        key: s3Key,
        date: s3Date,
    };
}

exports.handler = async (event, context) => {
    logger.info("Starting LLM log fetcher Lambda (Node.js)");

    try {
        // 1. Load config from Secrets Manager
        const config = await getConfig();
        logger.info("Loaded config from Secrets Manager");

        // 2. Download private key from S3 to /tmp
        const keyPath = await downloadPrivateKey(config);

        // 3. Build remote log path and local temp path
        const { remotePath, filename, s3Date } = buildRemoteLogPath(config);
        const localPath = path.join(os.tmpdir(), filename);

        // 4. Fetch the log file via SFTP
        await fetchRemoteLog(config, keyPath, remotePath, localPath);

        // 5. Upload the log file into the raw logs bucket
        const result = await uploadToS3(config, localPath, filename, s3Date);

        logger.info("Log fetch complete:", result);

        return {
            statusCode: 200,
            body: JSON.stringify(result),
        };
    } catch (err) {
        logger.error("Lambda failed:", err);
        return {
            statusCode: 500,
            body: JSON.stringify({
                error: err.message || "Unknown error",
            }),
        };
    }
};