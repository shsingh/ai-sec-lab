FROM python:3.14-slim
RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu
# [semantic] extra = sentence-transformers + the MiniLM model used by NOVA's semantics tier
RUN pip install --no-cache-dir "laya[serve]" "nova-hunting[semantic]" fastapi uvicorn httpx
# pre-download the semantic model at build time so first scan is warm
RUN python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('all-MiniLM-L6-v2')"
WORKDIR /app
COPY app.py /app/app.py
ENV PYTHONUNBUFFERED=1 LAYA_HOME=/models
VOLUME /models
EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
