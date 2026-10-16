"""Run synthetic Faith checks in an ephemeral Daytona sandbox. Opt-in only."""
import io
import os
import zipfile
from pathlib import Path


def main():
    # Shared runtime file is ignored by Git and never included in the upload archive.
    from dotenv import load_dotenv
    load_dotenv(Path(__file__).resolve().parents[1] / "backend/.env")
    if not os.getenv("DAYTONA_API_KEY"):
        raise SystemExit("Set DAYTONA_API_KEY in your runtime environment first.")
    from daytona import CreateSandboxFromSnapshotParams, Daytona
    from uuid import uuid4
    root = Path(__file__).resolve().parents[1]
    archive = io.BytesIO()
    # Explicit allowlist prevents .env, Git history, tokens, local DBs, and recordings leaving the machine.
    files = [root / "backend/requirements.txt", root / "backend/pyproject.toml", root / "scripts/evaluate.py"]
    for folder, extensions in [("backend/app", {".py"}), ("backend/tests", {".py"}), ("web", {".html", ".css", ".js", ".svg"})]:
        files.extend(path for path in (root / folder).rglob("*") if path.suffix in extensions and path.is_file())
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zipped:
        for path in files:
            zipped.write(path, path.relative_to(root))
    daytona = Daytona()
    sandbox = daytona.create(CreateSandboxFromSnapshotParams(
        name="faith-check-" + uuid4().hex[:8],
        labels={"app": "faith", "purpose": "synthetic-checks"},
        auto_stop_interval=5,
        ttl_minutes=10,
    ))
    try:
        sandbox.fs.upload_file(archive.getvalue(), "/tmp/faith-checks.zip")
        result = sandbox.process.exec("python -c \"import zipfile; zipfile.ZipFile('/tmp/faith-checks.zip').extractall('/tmp/faith')\"", timeout=30)
        if result.exit_code != 0:
            raise RuntimeError("Sandbox setup failed")
        for command in ["python -m pip install -r backend/requirements.txt", "python -m pytest -q backend/tests", "python scripts/evaluate.py"]:
            result = sandbox.process.exec(command, cwd="/tmp/faith", timeout=120, env={"PYTHONPATH": "/tmp/faith/backend", "FAITH_AI_PROVIDER": "local", "FAITH_DATABASE_PATH": "/tmp/faith-test.sqlite3"})
            print(result.result)
            if result.exit_code != 0:
                raise SystemExit(result.exit_code)
    finally:
        daytona.delete(sandbox, wait=True)


if __name__ == "__main__":
    main()
