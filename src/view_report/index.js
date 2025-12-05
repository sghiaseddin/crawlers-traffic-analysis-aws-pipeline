/**
 * Lambda: view_report
 *
 * This Lambda is intended to be exposed via a Lambda Function URL or API Gateway.
 *
 * Responsibilities:
 * - Read config from Secrets Manager (same secret: llm-log-pipeline-config)
 * - Determine which report to show:
 *     * default: yesterday's date (UTC)
 *     * optional: ?date=YYYY-MM-DD query parameter
 * - Load the JSON report from S3:
 *     s3://LOG_OUTPUT_BUCKET/LOG_ANALYSIS_PREFIX/bot-report-YYYY-MM-DD.json
 * - Render a simple HTML page with:
 *     * overall summary
 *     * table of bots
 *     * top paths per bot
 *     * basic charts using Chart.js
 *
 * Note: We use Buffer explicitly for base64 encoding JSON to embed in HTML safely.
 */

const { SecretsManagerClient, GetSecretValueCommand } = require("@aws-sdk/client-secrets-manager");
const { S3Client, GetObjectCommand } = require("@aws-sdk/client-s3");
const { LambdaClient, InvokeCommand } = require("@aws-sdk/client-lambda");

const secretsClient = new SecretsManagerClient({});
const s3Client = new S3Client({});
const lambdaClient = new LambdaClient({});

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

    return JSON.parse(secretString);
}

function getDateFromEvent(event) {
    // Default: yesterday in UTC
    const now = new Date();

    let targetDateStr;
    const qs = event?.queryStringParameters || {};

    if (qs.date) {
        // If user explicitly requested a date, use it as-is (YYYY-MM-DD expected)
        targetDateStr = qs.date;
    } else {
        const y = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
        y.setUTCDate(y.getUTCDate() - 1);
        const yyyy = y.getUTCFullYear();
        const mm = String(y.getUTCMonth() + 1).padStart(2, "0");
        const dd = String(y.getUTCDate()).padStart(2, "0");
        targetDateStr = `${yyyy}-${mm}-${dd}`;
    }

    return targetDateStr;
}

async function streamToString(stream) {
    return await new Promise((resolve, reject) => {
        const chunks = [];
        stream.on("data", (chunk) => chunks.push(chunk));
        stream.on("error", reject);
        stream.on("end", () => resolve(Buffer.concat(chunks).toString("utf-8")));
    });
}

async function loadReportForDate(config, dateStr) {
    const analysisBucket = config["LOG_OUTPUT_BUCKET"];
    let analysisPrefix = config["LOG_ANALYSIS_PREFIX"] || "reports";

    if (analysisPrefix && !analysisPrefix.endsWith("/")) {
        analysisPrefix = analysisPrefix + "/";
    }

    const key = `${analysisPrefix}bot-report-${dateStr}.json`;

    const cmd = new GetObjectCommand({
        Bucket: analysisBucket,
        Key: key,
    });

    const resp = await s3Client.send(cmd);
    const text = await streamToString(resp.Body);
    const data = JSON.parse(text);

    return { data, bucket: analysisBucket, key };
}

function renderHtml(report, dateStr, s3Uri) {
    const windowFrom = report.window?.from || "";
    const windowTo = report.window?.to || "";
    const overall = report.overall || {};
    const bots = report.bots || [];

    const overallTotal = overall.total_requests || 0;
    const uniqueBots = overall.unique_bots || bots.length;
    const uniquePaths = overall.unique_paths || 0;

    // Build bots table rows
    const botRowsHtml = bots
        .map(
            (b) => `
      <tr>
        <td>${escapeHtml(b.bot_name)}</td>
        <td>${b.is_llm ? "LLM" : "Other"}</td>
        <td>${b.total_requests}</td>
        <td>${b.daily_requests.length}</td>
        <td>${b.top_paths.length}</td>
      </tr>
    `
        )
        .join("");

    // Build top paths per bot sections
    const botPathSections = bots
        .map((b) => {
            const topPathsRows = (b.top_paths || [])
                .slice(0, 20)
                .map(
                    (p) => `
          <tr>
            <td>${escapeHtml(p.path)}</td>
            <td>${p.requests}</td>
          </tr>
        `
                )
                .join("");

            return `
        <section class="bot-section">
          <h3>${escapeHtml(b.bot_name)} ${b.is_llm ? "(LLM)" : ""}</h3>
          <div class="bot-meta">
            <span>Total requests: <strong>${b.total_requests}</strong></span>
          </div>
          <table class="paths-table">
            <thead>
              <tr>
                <th>Path</th>
                <th>Requests</th>
              </tr>
            </thead>
            <tbody>
              ${topPathsRows}
            </tbody>
          </table>
        </section>
      `;
        })
        .join("");

    // Encode report JSON as base64 to safely embed into HTML and decode in the browser
    const reportJsonBase64 = Buffer.from(JSON.stringify(report)).toString("base64");

    return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>Bot Traffic Report - ${dateStr}</title>
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <style>
    body {
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      margin: 0;
      padding: 0;
      background: #0f172a;
      color: #e5e7eb;
    }
    header {
      padding: 1.5rem 2rem;
      background: #020617;
      border-bottom: 1px solid #1e293b;
    }
    h1 {
      margin: 0;
      font-size: 1.6rem;
    }
    main {
      padding: 1.5rem 2rem 3rem;
      max-width: 1100px;
      margin: 0 auto;
    }
    .summary-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
      gap: 1rem;
      margin: 1.5rem 0;
    }
    .card {
      background: #020617;
      border-radius: 0.75rem;
      padding: 1rem 1.2rem;
      border: 1px solid #1e293b;
    }
    .card h2 {
      font-size: 0.9rem;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      color: #9ca3af;
      margin: 0 0 0.4rem;
    }
    .card .value {
      font-size: 1.4rem;
      font-weight: 600;
    }
    .card small {
      color: #6b7280;
      display: block;
      margin-top: 0.3rem;
    }
    section {
      margin-top: 2rem;
    }
    h2 {
      font-size: 1.2rem;
      margin-bottom: 0.75rem;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      margin-top: 0.75rem;
      font-size: 0.9rem;
    }
    thead {
      background: #020617;
    }
    th, td {
      padding: 0.5rem 0.6rem;
      border-bottom: 1px solid #1e293b;
      text-align: left;
    }
    th {
      font-weight: 500;
      color: #9ca3af;
    }
    tr:nth-child(even) td {
      background: #02061744;
    }
    .bot-section {
      margin-top: 1.5rem;
      padding: 1rem 1.2rem;
      border-radius: 0.75rem;
      background: #020617;
      border: 1px solid #1e293b;
    }
    .bot-section h3 {
      margin-top: 0;
      margin-bottom: 0.4rem;
    }
    .bot-meta {
      font-size: 0.9rem;
      color: #9ca3af;
      margin-bottom: 0.5rem;
    }
    .charts {
      display: grid;
      grid-template-columns: minmax(0, 1fr);
      gap: 1rem;
    }
    canvas {
      max-width: 100%;
      background: #020617;
      border-radius: 0.75rem;
      padding: 0.5rem;
      border: 1px solid #1e293b;
    }
    footer {
      padding: 1rem 2rem 2rem;
      font-size: 0.8rem;
      color: #6b7280;
      text-align: center;
    }
    code {
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
      font-size: 0.85em;
    }
  </style>
  <!-- Chart.js from CDN -->
  <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
</head>
<body>
  <header>
    <h1>Bot Traffic Report – ${dateStr}</h1>
  </header>
  <main>
    <div class="summary-grid">
      <div class="card">
        <h2>Total Bot Requests</h2>
        <div class="value">${overallTotal}</div>
        <small>Window: ${windowFrom} → ${windowTo}</small>
      </div>
      <div class="card">
        <h2>Unique Bots</h2>
        <div class="value">${uniqueBots}</div>
        <small>From bot_map.json matches</small>
      </div>
      <div class="card">
        <h2>Unique Paths</h2>
        <div class="value">${uniquePaths}</div>
        <small>Across all bots in this window</small>
      </div>
      <div class="card">
        <h2>Report Source</h2>
        <div class="value">JSON</div>
        <small><code>${escapeHtml(s3Uri)}</code></small>
      </div>
    </div>

    <section>
      <h2>Bots Overview</h2>
      <div class="charts">
        <canvas id="botTotalsChart" height="250"></canvas>
        <canvas id="dailyChart" height="250"></canvas>
      </div>
      <table>
        <thead>
          <tr>
            <th>Bot Name</th>
            <th>Type</th>
            <th>Total Requests</th>
            <th>Days Seen</th>
            <th>Distinct Paths</th>
          </tr>
        </thead>
        <tbody>
          ${botRowsHtml}
        </tbody>
      </table>
    </section>

    <section>
      <h2>Top Paths per Bot</h2>
      ${botPathSections}
    </section>
  </main>
  <footer>
    Generated at <code>${escapeHtml(report.generated_at || "")}</code>
  </footer>

  <script>
    // Embed report JSON for client-side usage (base64-decoded)
    window.REPORT_DATA = JSON.parse(atob("${reportJsonBase64}"));
    (function() {
      const data = window.REPORT_DATA || {};
      const bots = data.bots || [];

      // --- Bot totals bar chart ---
      const labels = bots.map(b => b.bot_name);
      const totals = bots.map(b => b.total_requests);
      const ctx1 = document.getElementById("botTotalsChart");
      if (ctx1 && labels.length > 0) {
        new Chart(ctx1, {
          type: "bar",
          data: {
            labels,
            datasets: [
              {
                label: "Total Requests per Bot",
                data: totals
              }
            ]
          },
          options: {
            responsive: true,
            plugins: {
              legend: { display: false },
              title: {
                display: true,
                text: "Bot Activity – Total Requests"
              }
            },
            scales: {
              x: {
                ticks: { color: "#e5e7eb" },
                grid: { color: "#1e293b" }
              },
              y: {
                ticks: { color: "#e5e7eb" },
                grid: { color: "#1e293b" },
                beginAtZero: true
              }
            }
          }
        });
      }

      // --- Daily time series chart for top N bots ---
      const topN = 5;
      const topBots = bots.slice(0, topN);

      const allDatesSet = new Set();
      topBots.forEach(b => {
        (b.daily_requests || []).forEach(p => allDatesSet.add(p.date));
      });
      const allDates = Array.from(allDatesSet).sort();

      const datasets = topBots.map((b, idx) => {
        const map = {};
        (b.daily_requests || []).forEach(p => {
          map[p.date] = p.requests;
        });
        const dataPoints = allDates.map(d => map[d] || 0);

        return {
          label: b.bot_name,
          data: dataPoints
        };
      });

      const ctx2 = document.getElementById("dailyChart");
      if (ctx2 && allDates.length > 0 && datasets.length > 0) {
        new Chart(ctx2, {
          type: "line",
          data: {
            labels: allDates,
            datasets: datasets
          },
          options: {
            responsive: true,
            plugins: {
              title: {
                display: true,
                text: "Daily Requests – Top Bots"
              }
            },
            scales: {
              x: {
                ticks: { color: "#e5e7eb" },
                grid: { color: "#1e293b" }
              },
              y: {
                ticks: { color: "#e5e7eb" },
                grid: { color: "#1e293b" },
                beginAtZero: true
              }
            }
          }
        });
      }
    })();
  </script>
</body>
</html>`;
}

function renderLoadingHtml(dateStr) {
    const safeDate = escapeHtml(dateStr);
    return `<!DOCTYPE html>
  <html lang="en">
  <head>
    <meta charset="UTF-8" />
    <title>Generating Report – ${safeDate}</title>
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <style>
      body {
        font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        background: #0f172a;
        color: #e5e7eb;
        display: flex;
        align-items: center;
        justify-content: center;
        height: 100vh;
        margin: 0;
      }
      .box {
        background: #020617;
        border-radius: 0.75rem;
        padding: 1.5rem 2rem;
        border: 1px solid #1e293b;
        max-width: 520px;
        text-align: center;
      }
      h1 {
        margin-top: 0;
        font-size: 1.4rem;
      }
      p {
        color: #9ca3af;
        font-size: 0.95rem;
      }
      .spinner {
        margin: 1rem auto 0.75rem;
        width: 36px;
        height: 36px;
        border-radius: 999px;
        border: 4px solid #1e293b;
        border-top-color: #38bdf8;
        animation: spin 0.8s linear infinite;
      }
      @keyframes spin {
        to {
          transform: rotate(360deg);
        }
      }
      code {
        font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
        font-size: 0.85em;
      }
    </style>
  </head>
  <body>
    <div class="box">
      <h1>Preparing report for ${safeDate}…</h1>
      <div class="spinner"></div>
      <p>
        We&apos;re generating the bot traffic analysis for this date.
        This usually takes a few seconds.
      </p>
      <p>
        The page will automatically refresh when the report is ready.
      </p>
    </div>
    <script>
      (function poll() {
        var url = new URL(window.location.href);
        url.searchParams.set("force", "1");
        fetch(url.toString(), { cache: "no-store" })
          .then(function (resp) {
            return resp.text().then(function (text) {
              return { resp: resp, text: text };
            });
          })
          .then(function (result) {
            var resp = result.resp;
            var text = result.text || "";
            // When the full report HTML is ready, it contains the REPORT_DATA embed
            if (resp.ok && text.indexOf("window.REPORT_DATA") !== -1) {
              document.open();
              document.write(text);
              document.close();
            } else {
              setTimeout(poll, 4000);
            }
          })
          .catch(function () {
            setTimeout(poll, 5000);
          });
      })();
    </script>
  </body>
  </html>`;
}

function escapeHtml(str) {
    return String(str)
        .replace(/&/g, "&amp;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#39;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;");
}

exports.handler = async (event) => {
    try {
        const cfg = await getConfig();
        const dateStr = getDateFromEvent(event);
        const qs = event?.queryStringParameters || {};
        const forceOnly = qs.force === "1";

        let reportData;
        let s3Uri;

        try {
            // First attempt: load existing report for this date
            const { data, bucket, key } = await loadReportForDate(cfg, dateStr);
            reportData = data;
            s3Uri = `s3://${bucket}/${key}`;
        } catch (err) {
            console.error("Error loading report on first attempt:", err);

            const analysisLambdaName = cfg["LOG_ANALYSIS_LAMBDA_NAME"];

            // If this is NOT a polling request, try to trigger the analysis Lambda asynchronously
            if (!forceOnly && analysisLambdaName) {
                try {
                    const invokeCmd = new InvokeCommand({
                        FunctionName: analysisLambdaName,
                        InvocationType: "Event", // fire-and-forget
                        Payload: Buffer.from(JSON.stringify({ date: dateStr })),
                    });
                    await lambdaClient.send(invokeCmd);
                } catch (invokeErr) {
                    console.error("Error triggering analysis Lambda:", invokeErr);
                }
            } else if (!analysisLambdaName) {
                console.error("LOG_ANALYSIS_LAMBDA_NAME not set in config; cannot trigger analysis.");
            }

            // Always return a loading page here; the client will poll with ?force=1
            const html = renderLoadingHtml(dateStr);
            return {
                statusCode: 200,
                headers: {
                    "Content-Type": "text/html; charset=utf-8",
                },
                body: html,
            };
        }

        const html = renderHtml(reportData, dateStr, s3Uri);

        return {
            statusCode: 200,
            headers: {
                "Content-Type": "text/html; charset=utf-8"
            },
            body: html
        };
    } catch (err) {
        console.error("Fatal error in view_report Lambda:", err);
        return {
            statusCode: 500,
            headers: {
                "Content-Type": "text/plain; charset=utf-8"
            },
            body: "Internal error in view_report Lambda"
        };
    }
};
