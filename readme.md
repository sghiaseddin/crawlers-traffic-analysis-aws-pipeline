# LLM Bot Traffic Analysis Pipeline
## Version 0.5.6

Serverless AWS solution for detecting and analyzing Large Language Model (LLM) crawlers.

## Use Case

### Business Problem

As LLM bots like GPTBot, PerplexityBot, ClaudeBot, and others increasingly crawl websites to collect training data, companies need visibility into:
- How frequently these bots access their website
- Which specific crawlers are doing it
- Which pages they are collecting content from
- How this behavior changes over time

Currently, traditional web tracking tools like Google Analytics cannot detect these bots because they rely on JavaScript execution within the user’s browser to capture activity, and since crawlers do not execute JavaScript but only read the HTML content directly, their visits go unnoticed. Web access logs contain this information, but it is buried inside large, compressed `.gz` log files that require manual inspection and technical expertise to interpret. This pipeline automates the entire process from retrieving, parsing, and analyzing raw access logs to producing clear, daily and cumulative CSV reports and visual summaries.

## Stakeholders

| Stakeholder | Role | Benefit |
| --- | --- | --- |
| Marketing & SEO Managers | Monitor how AI crawlers interact with public content | Understand exposure of site content to LLMs and bots, including visibility in LLM-based search experiences used by end users |
| IT & DevOps Teams | Oversee website integrity and resource usage | Detect potential scraping or aggressive crawling behavior and leverage insights to adjust firewall rules, update robots.txt, and improve crawl management |
| Data Analysts | Study long-term bot activity trends | Correlate with SEO performance, security events, or content updates |
| Executives / Decision Makers | Get high-level insights | See how AI models might be using company data and plan strategic responses |

## Project Goal

### Goal Statement

Develop a serverless, configurable AWS data pipeline that automatically ingests daily web server access logs, classifies and analyzes LLM bot traffic, and produces:
1. Daily detailed CSV reports (bot activity per page)
2. Cumulative summary CSV reports (aggregated by bot type and timeframe)
3. A publicly viewable HTML analytics dashboard (via GoAccess)

The entire system deploys automatically using a single Bash script, configurable through a `.env` file, making it reusable for any website with minimal setup.

### Fit for the Use Case

This approach is ideal because:
- It uses serverless AWS components, ensuring scalability and low maintenance.
- It automates every step, avoiding manual file transfers or command-line parsing.
- It produces business-friendly outputs (CSV and HTML) without requiring technical data tools.
- It is fully configurable, so it can be replicated across multiple client websites or servers.

## Architecture Overview

The pipeline operates step-by-step as follows: First, the Secrets Manager securely stores SSH keys and credentials needed to access the remote web servers. AWS Lambda functions then use these secrets to securely fetch daily compressed access logs via SCP. Once the logs are retrieved, the ETL Processor (implemented using AWS Glue or Lambda) unzips, parses, and classifies the log data into structured CSV files. The Data Analyzer component further processes these CSVs using Python analytics to generate daily per-bot/page summaries and cumulative reports. Meanwhile, the Report Generator runs a Docker container with GoAccess to create an HTML dashboard visualizing the bot traffic, which is then uploaded to a public S3 bucket for easy access. Throughout this process, the Automation and Config module orchestrates deployment and configuration using a Bash script and AWS CLI, ensuring all components work together seamlessly and are configurable via environment variables.

| Module | Description | Technology | Official Documentation |
| --- | --- | --- | --- |
| Secrets Manager Module | Manages SSH keys and credentials securely across the pipeline | AWS Secrets Manager | https://AWS.amazon.com/secrets-manager/ |
| Log Fetcher | Securely copies daily `.gz` access logs from a remote web server via SSH/SCP; runs daily to fetch the data for the previous day | AWS Lambda and Secrets Manager | https://AWS.amazon.com/lambda/ |
| ETL Processor | Unzips, parses, classifies, and aggregates logs into structured CSV data | AWS Glue (PySpark) or AWS Lambda (Python) | https://AWS.amazon.com/glue/ |
| Data Analyzer | Uses Python-based analytics to produce daily per-bot/page CSV and cumulative summary CSV | AWS Lambda or AWS Batch (Python and pandas) | https://AWS.amazon.com/batch/ |
| Report Generator | Renders a GoAccess HTML dashboard using a Docker container running GoAccess and uploads to a public S3 bucket | Docker container, S3 static website hosting | https://AWS.amazon.com/s3/, https://goaccess.io/ |
| Automation and Config | Deploys and configures all components from `.env` variables | Bash and AWS CLI | https://AWS.amazon.com/cli/ |


## Input Files

```log
172.213.21.159 www.builderleadconverter.com - [01/Oct/2025:05:41:30 +0000] "GET /digital-marketing-strategy-for-a-construction-company/ HTTP/2.0" 200 31450 "-" "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ChatGPT-User/1.0; +https://openai.com/bot" | TLSv1.3 | 0.027 0.030 0.031 MISS 0 NC:000000 UP:-
216.144.248.24 www.builderleadconverter.com - [01/Oct/2025:05:58:49 +0000] "GET / HTTP/2.0" 304 0 "https://builderleadconverter.com" "Mozilla/5.0+(compatible; UptimeRobot/2.0; http://www.uptimerobot.com/)" | TLSv1.3 | 0.050 0.050 0.051 MISS 0 NC:000000 UP:-
110.238.105.89 www.builderleadconverter.com - [01/Oct/2025:06:02:44 +0000] "GET /wp-content/uploads/2021/03/flip-card8.jpg HTTP/2.0" 404 15310 "https://www.builderleadconverter.com/sales-automation/" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36" | TLSv1.3 | 1.847 1.854 1.854 MISS 0 NC:000000 UP:-
```

## Output Files

| Output | Format | Example Path | Purpose |
| --- | --- | --- | --- |
| Daily Raw Logs | .log | `s3://<RAW_BUCKET>/raw/date=2025-10-31/` | Source logs pulled from web server |
| Daily Bot Summary | .csv | `s3://<REPORTS_BUCKET>/summaries/date=2025-10-31/summary.csv` | Daily count by bot and pages hit |
| Cumulative Report | .csv | `s3://<REPORTS_BUCKET>/cumulative/cumulative_summary.csv` | All-time aggregated results |
| Public Dashboard | .html | `s3://<PUBLIC_BUCKET>/site/index.html` | Visual analytics all-time (GoAccess) |

## Example Insights (from CSV)

Example daily bot metrics:

| date | bot | total_hits | unique_ips | unique_pages |
| --- | --- | --- | --- | --- |
| 2025-10-29 | GPTBot | 1532 | 47 | 412 |
| 2025-10-29 | PerplexityBot | 682 | 19 | 158 |
| 2025-10-29 | ClaudeBot | 244 | 11 | 99 |

Example cumulative per-page activity by bot:

| page | bot | hits |
| --- | --- | --- |
| / | GPTBot | 210 |
| /sales-automation/ | PerplexityBot | 89 |
| /services/ | GPTBot | 55 |

## Risks and Mitigations

| Risk | Description | Mitigation |
| --- | --- | --- |
| SSH key exposure or unauthorized access risk | Lambda unable to connect and pull logs | Secure storage of SSH keys in AWS Secrets Manager, restricted IAM permissions, and automated retries |
| Unexpected bot user-agent names | New LLM crawlers may not match regex patterns | Maintain a versioned `bot_map.json` file for easy updates |
| Large log volumes | Very large websites could exceed Lambda memory limits | Use AWS Glue or Batch (PySpark or pandas chunking) for scalable ETL |
| Cost creep over time | Daily processing and storage | Lifecycle policies to expire raw logs after a defined number of days |

## Repository Structure (Planned)

```
deploy/
  deploy_llm_log_pipeline.sh     # Automated deployment script
src/
  lambda_fetch_logs_node/        # Node.js app to fetch log files using ssh and trigger the ETL
  glue_etl/                      # Log parser and CSV generator
  data_analysis/                 # Python analytics (CSV aggregation)
  docker_goaccess/               # Docker container running GoAccess HTML generator
    Dockerfile                   # Dockerfile to build GoAccess container image
config/
  bot_map.json                   # Regex map of known bots
.env.example                     # Config template
README.md                        # Documentation (this file)
```

## KPIs and Quality Metrics

### Acceptance Criteria

- **Data Completeness:** All daily access logs should be ingested without missing files.
- **Classification Accuracy:** Bot classification must correctly identify known LLM crawlers with minimal false positives or negatives.
- **Timely Delivery:** Daily reports and dashboards must be generated and available within a defined SLA (e.g., by 8 AM UTC the following day).

### Benchmark Process Using Google Search Console Crawl Stats

- A CSV export of Google Search Console Crawl Stats can be uploaded to an S3 bucket.
- A dedicated Python pipeline compares the `GoogleBot` hits from the daily bot summary CSV reports with the corresponding Crawl Stats data.
- Accuracy is calculated as the ratio of matched crawls (from logs) to the total recorded crawls (from Google Search Console) for the same period.

## Authors

- **Shayan Ghiaseddin**: MSc Business Informatics – Corvinus University of Budapest

- **Máté Móger**: MSc Business Informatics – Corvinus University of Budapest

This is group project for Data Engineering course by Szabó Ildikó Borbásné and Zoltán Balogh, at Corvinus University of Budapest, Autumn 2025

---
## Changelog

### v0.5.6
- Fixed: Bash script (step 11) to set a trigger for lambda_etl_logs on file add to raw files bucket
- Added: The manual trigger to fetch the logs at the end of pipeline

### v0.5.5
- Created: Bash script (step 11) to set trigger for lambda function in EventBridge
- Created: Bash script (step 12) to build node package to create a lambda function for viewing reports (html)

### v0.5.4
- Created: Bash script (step 10) to set database and crawler in the Glue

### v0.5.3
- Created: Bash script (step 8) to create all the buckets needed in the pipeline
- Created: Bash script (step 9) to upload ssh private key to the ssh-key-bucket

### v0.5.2
- Created: Bash script (step 7) to build GoAccess lambda function which is use a custom layer
- Created: A custom layer using GoAccess binary on ARM64

### v0.5.1
- Created: Bash script (step 5) to build ETL lambda function 
- Created: Bash script (step 6) to build Log Analyzer lambda function 
- Improved: File base structure

### v0.5.0
- Created: Bash script deploy logic, single deploy pipeline with multiple steps
- Created: Bash scripts to read and load .env and AWS credentials
- Created: Bash script (step 3) to store secrets and naming conventions in the AWS Secret Manager
- Created: Bash Script (step 4) to build node package to create a lambda function to pull data from external service

### v0.4.0
- Idea: Implement a Docker container in ECS to run GoAccess... in AWS Academy Lab we don't have permission to create a cluster
- Created: Using Docker on my local machine I created a goaccess as binary for ARM
- Created: lambda function to use goaccess binary as a layer and create a report using .log file
- Modified: View Report app now have a welcome message and buttons to retrieve our analysis report or GoAccess report

### v0.3.1
- Improved: Report View app to trigger the analysis lambda function if the report .json not available
- Imporved: Report View show a message and loader while waiting for the analysis to be generated

### v0.3.0
- Created: Analysis lambda function to answer the questions of the research and store the report in the output bucket as json
- Created: Node.js app to render the report .json file and show on a AWS url

### v0.2.1
- Edited: ETL lambda function to output aggregated .csv and .log file too

### v0.2.0
- Created: ETL lambda function to prepare csv from raw .gz log
- Created: Glue Crawler to generate schema on data catalogue
- Improved: bot_map.json to include more signatures and IP ranges for some LLM bot crawlers 

### v0.1.1
- Improved: fetch function compare log files in external with bucket and copy only new items, except today's log 

### v0.1.0
- Created: lambda function to fetch logs using ssh connection, in node.js. source: https://stackoverflow.com/questions/57127454/accessing-and-copying-files-from-sftp-server-using-AWS-lambda-nodejs

---
## License

This project is released under the **MIT License**.
