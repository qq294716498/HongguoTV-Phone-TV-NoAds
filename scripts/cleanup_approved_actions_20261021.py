import hashlib
import json
import os
from pathlib import Path
import sys
import time
from datetime import datetime, timezone
import urllib.error
import urllib.request

REPO = "qq294716498/HongguoTV-Phone-TV-NoAds"
BASE = "https://api.github.com/repos/" + REPO
PLAN_HASH = "581fc9f46a7b5252fae6491cd2de5f6d23e3dbcbfaea07f92aad9fdfeebdc4df"
PROTECTED = set([39585798727,39585054502,39583037465,39583037347,39580851341,39580851183,39580410513,39580410478,39576473415,39576473391,39575287871,39575287710,39573681031,39573680597,39572210011,39572209759,39571062905,39571062609,39413727716,39413727665,39413727599,39413727517,39400771038,39400770963,39400770924,39400770885,39225469487,39225465466,39107356975,38992467269,38991254539,38867664567])
CRITICAL = {39580851183, 39583037347, 39583037465, 39585054502, 39585798727}
ROOT = Path(__file__).resolve().parents[1]
REPORT_PATH = Path(os.environ["RUNNER_TEMP"]) / "approved-actions-cleanup-report.json"
REPORT = {"startedUtc": datetime.now(timezone.utc).isoformat(), "planSha256": PLAN_HASH,
          "repository": REPO, "records": [], "preflight": [], "stopped": None,
          "protectedRunIds": sorted(PROTECTED), "verification": {}}
ALLOWED = set()


class ApiError(Exception):
    def __init__(self, status, message):
        self.status = status
        super().__init__(str(status) + ": " + message[:500])


def save():
    REPORT_PATH.write_text(json.dumps(REPORT, indent=2) + "\n", encoding="utf-8")


def api(path, method="GET"):
    if not path.startswith("/") and path != "":
        raise ValueError("Invalid API path")
    if method not in {"GET", "DELETE"}:
        raise ValueError("Unsupported HTTP method")
    if method == "DELETE" and path not in {"/actions/runs/" + str(i) for i in ALLOWED}:
        raise ValueError("Delete outside the approved fixed run IDs")
    request = urllib.request.Request(BASE + path, method=method, headers={
        "Authorization": "Bearer " + os.environ["GH_TOKEN"],
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "HongguoTV-approved-fixed-id-cleanup"})
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return 404, None
        raise ApiError(error.code, error.read(2048).decode("utf-8", "replace")) from None


def required(path):
    status, value = api(path)
    if status != 200:
        raise ValueError("Required resource unavailable: " + path + " HTTP " + str(status))
    return value


def paged(path, field=None):
    items = []
    for page in range(1, 101):
        separator = "&" if "?" in path else "?"
        data = required(path + separator + "per_page=100&page=" + str(page))
        chunk = data[field] if field else data
        if not isinstance(chunk, list):
            raise ValueError("Unexpected collection shape")
        items.extend(chunk)
        if len(chunk) < 100:
            return items
    raise ValueError("Collection pagination exceeded bound")


def artifacts(run_id):
    rows = paged("/actions/runs/" + str(run_id) + "/artifacts", "artifacts")
    return sorted([{"id": a["id"], "name": a["name"], "bytes": a["size_in_bytes"],
                    "expired": a["expired"], "digest": a.get("digest")} for a in rows],
                  key=lambda a: a["id"])


def release_snapshot():
    releases = paged("/releases")
    values = []
    for release in releases:
        rows = paged("/releases/" + str(release["id"]) + "/assets")
        values.append({k: release[k] for k in
                       ["id", "tag_name", "target_commitish", "draft", "prerelease", "body"]} |
                      {"assets": sorted([{k: a.get(k) for k in
                                          ["id", "name", "size", "digest", "state", "browser_download_url"]}
                                         for a in rows], key=lambda a: a["id"])})
    return sorted(values, key=lambda r: r["id"])


def refs_snapshot(kind):
    rows = required("/git/matching-refs/" + kind + "/")
    return sorted([{"ref": r["ref"], "sha": r["object"]["sha"],
                    "type": r["object"]["type"]} for r in rows], key=lambda r: r["ref"])


def protection_snapshot():
    runs = {}
    for run_id in sorted(PROTECTED):
        value = required("/actions/runs/" + str(run_id))
        runs[str(run_id)] = {"id": value["id"], "sha": value["head_sha"],
                             "created": value["created_at"]}
    return {"runs": runs, "criticalArtifacts": {str(i): artifacts(i) for i in sorted(CRITICAL)},
            "releases": release_snapshot(), "tags": refs_snapshot("tags"),
            "heads": refs_snapshot("heads")}


def state_for(record):
    status, run = api("/actions/runs/" + str(record["run"]))
    if status == 404:
        return "already_absent", None
    if status != 200:
        raise ValueError("Unexpected run response")
    if (run["id"] != record["run"] or run["head_sha"] != record["head"]
            or run["created_at"] != record["created"]
            or run.get("head_branch") != record.get("branch")):
        return "identity_changed", run
    if run["status"] != "completed":
        return "not_completed", run
    return "eligible", run


def append_result(value):
    REPORT["records"].append(value)
    save()
    print(json.dumps(value), flush=True)


def delete_one(record):
    run_id = record["run"]
    state, current = state_for(record)
    if state != "eligible":
        append_result({"run": run_id, "result": "skipped", "reason": state,
                       "currentStatus": current.get("status") if current else None})
        return
    approved_artifacts = {a["id"] for a in record["artifacts"]}
    current_artifacts = artifacts(run_id)
    if {a["id"] for a in current_artifacts} - approved_artifacts:
        append_result({"run": run_id, "result": "skipped", "reason": "new_unapproved_artifacts"})
        return
    state, current = state_for(record)
    if state != "eligible":
        append_result({"run": run_id, "result": "skipped", "reason": state})
        return
    result = {"run": run_id, "artifactsBefore": current_artifacts,
              "nominalLiveArtifactBytes": sum(a["bytes"] for a in current_artifacts if not a["expired"])}
    try:
        status, _ = api("/actions/runs/" + str(run_id), "DELETE")
    except Exception as error:
        result.update(result="uncertain", error=str(error))
        append_result(result)
        try:
            check, _ = api("/actions/runs/" + str(run_id))
            result["followupGetStatus"] = check
            if check == 404:
                result["result"] = "deleted_confirmed_after_error"
                save()
                return
        finally:
            save()
        raise RuntimeError("Delete outcome or permission requires review; no retry") from error
    if status == 404:
        result.update(result="skipped", reason="already_absent_at_delete")
        append_result(result)
        return
    if status != 204:
        result.update(result="failed", deleteHttpStatus=status)
        append_result(result)
        raise RuntimeError("Unexpected deletion status; no retry")
    result["deleteHttpStatus"] = status
    for attempt in range(3):
        checked, _ = api("/actions/runs/" + str(run_id))
        if checked == 404:
            result.update(result="deleted", verifiedGetStatus=404)
            append_result(result)
            return
        if attempt < 2:
            time.sleep(2)
    result.update(result="uncertain", reason="delete_204_but_run_still_present")
    append_result(result)
    raise RuntimeError("Deletion not confirmed; no repeated delete")


def main():
    global ALLOWED
    raw = (ROOT / "maintenance/actions-cleanup-plan-20261021-094700Z.json").read_bytes()
    if hashlib.sha256(raw).hexdigest() != PLAN_HASH:
        raise ValueError("Approved plan byte hash mismatch")
    plan = json.loads(raw)
    records = plan["runs"]
    ids = [r["run"] for r in records]
    if (plan["repository"] != REPO or len(ids) != 129 or len(set(ids)) != 129
            or any(type(i) is not int or i <= 0 for i in ids)
            or set(ids) & PROTECTED or int(os.environ["GITHUB_RUN_ID"]) in ids
            or not set(plan["protectedRuns"]).issubset(PROTECTED)
            or plan["availableArtifacts"] != 68 or plan["availableArtifactBytes"] != 4635433410
            or any(r["created"] >= "2026-10-21T09:47:00Z" for r in records)):
        raise ValueError("Approved scope or protection invariant mismatch")
    if os.environ.get("GITHUB_REPOSITORY") != REPO or required("")["full_name"] != REPO:
        raise ValueError("Repository mismatch")
    ALLOWED = set(ids)
    REPORT.update(candidateCount=129, approvedArtifactCount=68, approvedArtifactBytes=4635433410,
                  cleanupWorkflowRun=os.environ["GITHUB_RUN_ID"], sourceCommit=os.environ["GITHUB_SHA"])
    save()
    before = protection_snapshot()
    REPORT["protectionBefore"] = before
    for record in records:
        state, current = state_for(record)
        REPORT["preflight"].append({"run": record["run"], "state": state,
                                    "status": current.get("status") if current else None})
    save()
    try:
        for record in records:
            delete_one(record)
    except Exception as error:
        REPORT["stopped"] = str(error)
        save()
    after = protection_snapshot()
    REPORT["protectionAfter"] = after
    REPORT["verification"]["protectedResourcesUnchanged"] = before == after
    deleted = {r["run"] for r in REPORT["records"]
               if r["result"] in {"deleted", "deleted_confirmed_after_error"}}
    artifact_checks = []
    for record in records:
        if record["run"] not in deleted:
            continue
        for artifact in record["artifacts"]:
            status, _ = api("/actions/artifacts/" + str(artifact["id"]))
            artifact_checks.append({"run": record["run"], "artifact": artifact["id"], "httpStatus": status})
    REPORT["verification"]["deletedRunArtifacts"] = artifact_checks
    REPORT["verification"]["allDeletedRunArtifactsAbsent"] = all(a["httpStatus"] == 404 for a in artifact_checks)
    REPORT["counts"] = {
        "deleted": len(deleted),
        "skipped": sum(r["result"] == "skipped" for r in REPORT["records"]),
        "failedOrUncertain": sum(r["result"] in {"failed", "uncertain"} for r in REPORT["records"]),
        "notAttempted": 129 - len(REPORT["records"]),
        "artifactsConfirmedAbsent": sum(a["httpStatus"] == 404 for a in artifact_checks),
        "nominalDeletedLiveArtifactBytes": sum(r.get("nominalLiveArtifactBytes", 0)
            for r in REPORT["records"] if r["run"] in deleted)}
    REPORT["finishedUtc"] = datetime.now(timezone.utc).isoformat()
    save()
    print(json.dumps({"counts": REPORT["counts"], "stopped": REPORT["stopped"],
                      "protectedResourcesUnchanged": before == after,
                      "allDeletedRunArtifactsAbsent": REPORT["verification"]["allDeletedRunArtifactsAbsent"]}), flush=True)
    if (REPORT["stopped"] or before != after
            or not REPORT["verification"]["allDeletedRunArtifactsAbsent"]):
        return 1
    return 0


if __name__ == "__main__":
    save()
    try:
        sys.exit(main())
    except Exception as error:
        REPORT["stopped"] = str(error)
        REPORT["finishedUtc"] = datetime.now(timezone.utc).isoformat()
        save()
        print("Cleanup stopped: " + str(error), flush=True)
        sys.exit(1)
