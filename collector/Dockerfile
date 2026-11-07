FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY VERSION schema.sql collector.py esb_import.py import_history.py ./
ENV PYTHONUNBUFFERED=1
USER nobody
CMD ["python", "collector.py"]
