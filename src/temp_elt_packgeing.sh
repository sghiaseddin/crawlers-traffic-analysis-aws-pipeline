mkdir lambda-etl-deploy
cd lambda-etl-deploy

# Copy ETL code + bot map
cp ../src/etl_llm_logs.py .
cp ../config/bot_map.json .
cp ../src/etl_lambda.py .

zip -r llm-log-etl.zip .