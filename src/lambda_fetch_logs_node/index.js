const fs = require("fs");
const os = require("os");
const path = require("path");
const { promisify } = require("util");
const { SecretsManagerClient, GetSecretValueCommand } = require("@aws-sdk/client-secrets-manager");
const { S3Client, GetObjectCommand, PutObjectCommand, ListObjectsV2Command } = require("@aws-sdk/client-s3");
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

function parseTemplateParts(template) {
    const marker = "{date}";
    const idx = template.indexOf(marker);
    if (idx === -1) {
        throw new Error("LOG_FETCH_REMOTE_LOG_TEMPLATE must contain '{date}'");
    }
    const prefix = template.slice(0, idx);
    const suffix = template.slice(idx + marker.length);
    return { prefix, suffix };
}

async function getRemoteLogCandidates(config, sftp) {
    const template = config["LOG_FETCH_REMOTE_LOG_TEMPLATE"];
    if (!template) {
        throw new Error("LOG_FETCH_REMOTE_LOG_TEMPLATE missing in config");
    }

    const remoteDirRaw = config["LOG_FETCH_REMOTE_LOG_DIR"] || "";
    const maxDays = parseInt(config["LOG_FETCH_MAX_DAYS"] || "30", 10);

    const { prefix, suffix } = parseTemplateParts(template);

    let remoteDir = remoteDirRaw;
    if (!remoteDir) {
        remoteDir = ".";
    }

    const now = new Date();
    const yyyy = now.getUTCFullYear();
    const mm = String(now.getUTCMonth() + 1).padStart(2, "0");
    const dd = String(now.getUTCDate()).padStart(2, "0");
    const todayStr = `${yyyy}-${mm}-${dd}`;

    const files = await sftp.list(remoteDir);

    const candidates = [];

    for (const file of files) {
        // ssh2-sftp-client uses type '-' for regular files
        if (file.type !== "-") {
            continue;
        }

        const name = file.name;
        if (!name.startsWith(prefix) || !name.endsWith(suffix)) {
            continue;
        }

        const datePart = name.slice(prefix.length, name.length - suffix.length);

        // Expecting something like YYYY-MM-DD
        if (!/^\d{4}-\d{2}-\d{2}$/.test(datePart)) {
            continue;
        }

        // Skip today's log; it will only be complete at the end of the day
        if (datePart === todayStr) {
            continue;
        }

        const fileDate = new Date(datePart);
        if (Number.isNaN(fileDate.getTime())) {
            continue;
        }

        const ageMs = now.getTime() - fileDate.getTime();
        const ageDays = ageMs / (24 * 60 * 60 * 1000);
        if (ageDays < 0 || ageDays > maxDays) {
            // skip future or too-old files
            continue;
        }

        const dirForPath = remoteDirRaw && !remoteDirRaw.endsWith("/")
            ? `${remoteDirRaw}/`
            : remoteDirRaw;

        const remotePath = `${dirForPath || ""}${name}`;
        const s3Date = datePart;

        candidates.push({
            filename: name,
            remotePath,
            s3Date,
        });
    }

    return candidates;
}

async function getExistingS3LogFilenames(config) {
    const rawBucket = config["LOG_FETCH_RAW_BUCKET"];
    if (!rawBucket) {
        throw new Error("LOG_FETCH_RAW_BUCKET missing in config");
    }

    const prefix = "raw/";
    const cmd = new ListObjectsV2Command({
        Bucket: rawBucket,
        Prefix: prefix,
    });

    const resp = await s3Client.send(cmd);

    const existing = new Set();
    if (resp.Contents) {
        for (const obj of resp.Contents) {
            const key = obj.Key;
            if (!key) continue;
            const idx = key.lastIndexOf("/");
            if (idx === -1) continue;
            const filename = key.slice(idx + 1);
            if (filename) {
                existing.add(filename);
            }
        }
    }
    return existing;
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

        // 3. Prepare SFTP connection
        const host = config["LOG_FETCH_SSH_HOST"];
        const user = config["LOG_FETCH_SSH_USER"];
        const port = parseInt(config["LOG_FETCH_SSH_PORT"] || "22", 10);

        if (!host || !user) {
            throw new Error("LOG_FETCH_SSH_HOST or LOG_FETCH_SSH_USER missing in config");
        }

        const sftp = new SFTPClient();
        await sftp.connect({
            host,
            port,
            username: user,
            privateKey: fs.readFileSync(keyPath),
        });

        try {
            // 4. Determine which remote log files we care about (last N days)
            const candidates = await getRemoteLogCandidates(config, sftp);
            logger.info(`Found ${candidates.length} candidate remote log files`);

            // 5. Determine which log files already exist in S3
            const existing = await getExistingS3LogFilenames(config);
            logger.info(`Found ${existing.size} existing log files in S3`);

            const synced = [];

            for (const { filename, remotePath, s3Date } of candidates) {
                if (existing.has(filename)) {
                    logger.info(`Skipping ${filename}, already present in S3`);
                    continue;
                }

                const localPath = path.join(os.tmpdir(), filename);
                logger.info(`Fetching missing log ${filename} from ${remotePath} to ${localPath}`);

                await sftp.fastGet(remotePath, localPath);

                const result = await uploadToS3(config, localPath, filename, s3Date);
                synced.push(result);
            }

            logger.info(`Sync complete, ${synced.length} new files uploaded`);

            return {
                statusCode: 200,
                body: JSON.stringify({
                    synced,
                    totalCandidates: candidates.length,
                    alreadyPresent: candidates.length - synced.length,
                }),
            };
        } finally {
            try {
                await sftp.end();
            } catch (_) {
                // ignore
            }
        }
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