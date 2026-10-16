"""Read-only service checks and one synthetic Arize span. Never print keys/bodies."""
import concurrent.futures
import json
import logging
import os
import sys
from pathlib import Path

import httpx
from dotenv import load_dotenv


def authenticated_get(name, url, key_name, header):
    key = os.getenv(key_name)
    if not key:
        return {"service": name, "status": "not_configured"}
    try:
        with httpx.Client(timeout=20, follow_redirects=False) as client:
            response = client.get(url, headers={header: ("Bearer " if header == "Authorization" else "") + key})
        return {"service": name, "status": "authenticated" if response.is_success else "rejected", "http_status": response.status_code}
    except Exception as error:
        return {"service": name, "status": "connection_failed", "error_type": type(error).__name__}


def check_arize():
    if not os.getenv("ARIZE_API_KEY") or not os.getenv("ARIZE_SPACE_ID"):
        return {"service": "arize", "status": "needs_api_key_and_space_id"}
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import SimpleSpanProcessor, SpanExportResult
    from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

    collector = InMemorySpanExporter()
    provider = TracerProvider(resource=Resource.create({
        "openinference.project.name": "faith", "model_id": "faith", "service.name": "faith",
    }))
    provider.add_span_processor(SimpleSpanProcessor(collector))
    with provider.get_tracer("faith").start_as_current_span("faith.connection_check") as span:
        span.set_attribute("openinference.span.kind", "CHAIN")
        span.set_attribute("demo", True)
        span.set_attribute("synthetic", True)
    exporter = OTLPSpanExporter(endpoint="https://otlp.arize.com/v1/traces", timeout=20,
                                headers={"arize-api-key": os.environ["ARIZE_API_KEY"], "arize-space-id": os.environ["ARIZE_SPACE_ID"]})
    try:
        result = exporter.export(collector.get_finished_spans())
        return {"service": "arize", "status": "synthetic_span_accepted" if result == SpanExportResult.SUCCESS else "export_rejected"}
    except Exception as error:
        return {"service": "arize", "status": "connection_failed", "error_type": type(error).__name__}
    finally:
        exporter.shutdown()
        provider.shutdown()


def main():
    load_dotenv(Path(__file__).resolve().parents[1] / "backend/.env")
    # Third-party error bodies are intentionally excluded from this diagnostic output.
    logging.disable(logging.CRITICAL)
    checks = [
        lambda: authenticated_get("anchor", "https://api.anchorbrowser.io/v1/sessions/all/status", "ANCHOR_API_KEY", "anchor-api-key"),
        lambda: authenticated_get("daytona", os.getenv("DAYTONA_API_URL", "https://app.daytona.io/api").rstrip("/") + "/sandbox?page=1&limit=1", "DAYTONA_API_KEY", "Authorization"),
        check_arize,
    ]
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        results = list(pool.map(lambda check: check(), checks))
    results.append({"service": "surrealdb", "status": "configured_not_probed" if os.getenv("SURREAL_URL") else "needs_connection"})
    print(json.dumps({"checks": results}, indent=2))
    return 0 if all(check["status"] in {"authenticated", "synthetic_span_accepted", "configured_not_probed"} for check in results) else 1


if __name__ == "__main__":
    sys.exit(main())
