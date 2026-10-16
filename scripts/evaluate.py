"""Synthetic intent checks. No user data or paid inference by default."""
import argparse
import json
import sys
from datetime import date, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
from app.assistant import bedrock_intent, local_intent
from app.config import Settings
from app.integrations import configure_tracing, operation
from app.models import IntentRequest, SearchRequest

CASES = [
    ("Two train tickets to Boston tomorrow under $150", "train", 2, 15000),
    ("A flight from New York to Seattle under $900", "flight", 1, 90000),
    ("A movie with captions", "cinema", 1, None),
    ("A bus to Philadelphia", "bus", 1, None),
    ("A concert with step-free access", "event", 1, None),
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bedrock", action="store_true", help="Explicitly run paid Bedrock inference using runtime credentials")
    args = parser.parse_args()
    provider = configure_tracing()
    settings = Settings()
    passed = 0
    for index, (text, category, people, budget) in enumerate(CASES):
        request = IntentRequest(message=text, current=SearchRequest(date=date.today() + timedelta(days=7)))
        with operation("faith.evaluation", case_index=index, provider="bedrock" if args.bedrock else "local") as span:
            actual = bedrock_intent(request, settings) if args.bedrock else local_intent(request)
            correct = actual.category.value == category and actual.passengers == people and actual.max_price == budget
            span.set_attribute("eval.intent_correct", correct)
            passed += int(correct)
    if provider:
        provider.shutdown()
    print(json.dumps({"cases": len(CASES), "passed": passed, "accuracy": passed / len(CASES), "provider": "bedrock" if args.bedrock else "local"}))
    return 0 if passed == len(CASES) else 1


if __name__ == "__main__":
    raise SystemExit(main())
