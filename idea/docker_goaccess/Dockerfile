# Lightweight base image
FROM debian:bookworm-slim

# Install GoAccess + AWS CLI (for S3 IO) + basic tools
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        goaccess \
        awscli \
        ca-certificates \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

# Set a sane default timezone (can be overridden at runtime)
ENV TZ=UTC

# Working directory inside the container
WORKDIR /app

# Copy GoAccess configuration and entrypoint script into the image
# (entrypoint.sh will be implemented later)
COPY goaccess.conf /app/goaccess.conf
COPY entrypoint.sh /app/entrypoint.sh

# Ensure entrypoint is executable
RUN chmod +x /app/entrypoint.sh

# Environment variables that control behavior; these can be overridden at task/run time.
# - PROCESSING_BUCKET: S3 bucket where aggregated .log lives
# - AGGREGATED_LOG_KEY: key of the aggregated .log file (e.g. aggregated/all_logs.log)
# - OUTPUT_BUCKET: S3 bucket where HTML output should be stored
# - OUTPUT_KEY: key for the generated HTML report (e.g. reports/goaccess-report.html)
# - GOACCESS_CONFIG_FILE: path to goaccess.conf inside the container
ENV PROCESSING_BUCKET="tap-processing-logs" \
    AGGREGATED_LOG_KEY="aggregated/all_logs.log" \
    OUTPUT_BUCKET="tap-output" \
    OUTPUT_KEY="reports/goaccess-report.html" \
    GOACCESS_CONFIG_FILE="/app/goaccess.conf"

# Default entrypoint invokes our shell script, which will:
#  - download the aggregated log from S3
#  - run goaccess to generate an HTML report
#  - upload the report back to S3
ENTRYPOINT ["/app/entrypoint.sh"]
