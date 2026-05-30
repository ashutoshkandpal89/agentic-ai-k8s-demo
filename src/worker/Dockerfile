FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
COPY orchestrator.py .
COPY token_budget.py .
RUN useradd -m -u 1000 workeruser && chown -R workeruser /app
USER workeruser
EXPOSE 9090
CMD ["python", "main.py"]
