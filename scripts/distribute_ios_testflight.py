"""Distribute the build identified by a signed iOS release report."""

import argparse
import base64
import json
import os
from pathlib import Path
import re
import time
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


APP_ID = "1601013908"
ORIGIN = "https://api.appstoreconnect.apple.com"
DEFAULT_PROCESSING_TIMEOUT = 15 * 60
TESTING_STATES = {"READY_FOR_BETA_TESTING", "IN_BETA_TESTING"}
EXTERNAL_STATES = TESTING_STATES | {
    "READY_FOR_BETA_SUBMISSION", "WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW", "BETA_APPROVED",
}


class AppStoreConnect:
    def __init__(self, key_id, issuer_id, encoded_key):
        self.key_id = key_id
        self.issuer_id = issuer_id
        self.key = base64.b64decode("".join(encoded_key.split()), validate=True)

    def request(self, path, *, params=None, method="GET", payload=None):
        import jwt

        url = ORIGIN + path if path.startswith("/") else path
        if not url.startswith(ORIGIN + "/"):
            raise RuntimeError("Unexpected App Store Connect URL")
        if params:
            url += "?" + urlencode(params)
        token = jwt.encode(
            {"iss": self.issuer_id, "aud": "appstoreconnect-v1", "exp": int(time.time()) + 600},
            self.key,
            algorithm="ES256",
            headers={"kid": self.key_id},
        )
        body = json.dumps(payload).encode() if payload is not None else None
        request = Request(url, data=body, method=method, headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        })
        try:
            with urlopen(request, timeout=30) as response:
                return json.loads(response.read() or "{}")
        except HTTPError as error:
            try:
                errors = json.loads(error.read()).get("errors", [])
            except ValueError:
                errors = []
            details = "; ".join(
                item.get("detail") or item.get("title", "") for item in errors
            )[:500]
            raise RuntimeError(
                f"App Store Connect {method} failed with HTTP {error.code}. {details}"
            ) from error

    def items(self, path, params=None):
        page = self.request(path, params=params)
        yield from page["data"]
        while next_page := page.get("links", {}).get("next"):
            page = self.request(next_page)
            yield from page["data"]


def read_report(path, source_revision):
    report = json.loads(path.read_text())
    revision = report["revision"]
    version = report["version"]
    build = str(report["build"])
    if not (re.fullmatch(r"[a-f0-9]{8,40}", revision or "") and source_revision.startswith(revision)):
        raise ValueError("IPA verification report does not match the built commit")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", version or "") or not build.isdecimal():
        raise ValueError("Invalid version or build number in IPA verification report")
    return version, build


def poll_until(check, deadline, waiting_message, timeout_message):
    if time.monotonic() >= deadline:
        raise TimeoutError(timeout_message)
    result = check()
    if result is not None:
        return result
    print(waiting_message, flush=True)
    while (remaining := deadline - time.monotonic()) > 0:
        time.sleep(min(10, remaining))
        if time.monotonic() >= deadline:
            break
        result = check()
        if result is not None:
            return result
    raise TimeoutError(timeout_message)


def version_spellings(version):
    # App Store Connect may retain either spelling when a patch version is zero.
    parts = version.split(".")
    if len(parts) == 2:
        return (version, version + ".0")
    if len(parts) == 3 and parts[-1] == "0":
        return (version, ".".join(parts[:2]))
    return (version,)


def ios_builds(api, params):
    response = api.request("/v1/builds", params={
        "filter[app]": APP_ID, "include": "preReleaseVersion", **params,
    })
    ios_versions = {
        entry["id"] for entry in response.get("included", [])
        if entry["type"] == "preReleaseVersions" and entry["attributes"]["platform"] == "IOS"
    }
    return [
        build for build in response["data"]
        if build["relationships"]["preReleaseVersion"]["data"]["id"] in ios_versions
    ]


def wait_for_build(api, version, number, deadline):
    def ready():
        for spelling in version_spellings(version):
            builds = ios_builds(api, {
                "filter[preReleaseVersion.version]": spelling,
                "filter[version]": number,
            })
            if len(builds) > 1:
                raise RuntimeError(f"More than one matching iOS build for {version} ({number})")
            if not builds:
                continue
            build = builds[0]
            state = build["attributes"]["processingState"]
            if build["attributes"]["expired"] or state in {"INVALID", "FAILED"}:
                raise RuntimeError(f"TestFlight build {version} ({number}) is expired or invalid")
            if state == "VALID":
                return build["id"], spelling
            return None

    return poll_until(
        ready, deadline,
        f"Waiting for TestFlight to process iOS {version} ({number}).",
        f"TestFlight has not finished processing iOS {version} ({number}).",
    )


def find_groups(api, distribution):
    groups = list(api.items("/v1/betaGroups", {"filter[app]": APP_ID}))
    if distribution == "internal":
        internal_groups = [group for group in groups if group["attributes"]["isInternalGroup"]]
        if not internal_groups:
            raise RuntimeError("Logseq has no internal TestFlight groups")
        return internal_groups
    matches = [
        group for group in groups
        if not group["attributes"]["isInternalGroup"]
        and group["attributes"]["name"].casefold() == "mobile testers"
    ]
    if len(matches) != 1:
        raise RuntimeError("Expected exactly one external Mobile Testers group")
    return matches


def wait_for_beta_detail(api, build_id, state_key, deadline):
    def ready():
        details = list(api.items("/v1/buildBetaDetails", {"filter[build]": build_id}))
        if len(details) > 1:
            raise RuntimeError("Expected one TestFlight beta detail for the verified build")
        if details and details[0]["attributes"][state_key] != "PROCESSING":
            return details[0]

    return poll_until(
        ready, deadline,
        f"Waiting for TestFlight beta processing ({state_key}).",
        f"TestFlight beta processing did not complete ({state_key}).",
    )


def wait_for_review_slot(api, build_id, version, deadline):
    def available():
        builds = ios_builds(api, {
            "filter[preReleaseVersion.version]": version,
            "filter[betaAppReviewSubmission.betaReviewState]": "WAITING_FOR_REVIEW,IN_REVIEW",
            "filter[expired]": "false",
        })
        if any(build["id"] == build_id for build in builds):
            return False  # This build already has a review submission.
        if not builds:
            return True

    return poll_until(
        available, deadline,
        f"Waiting for the current iOS {version} Beta App Review to finish.",
        f"Another iOS {version} build is in Beta App Review. Rerun the distribution job after it clears.",
    )


def attach_build(api, group, build_id):
    # Automatic internal groups already have access to every eligible build.
    if group["attributes"]["isInternalGroup"] and group["attributes"].get("hasAccessToAllBuilds"):
        return

    path = f"/v1/betaGroups/{group['id']}/relationships/builds"

    def linked():
        return any(build["id"] == build_id for build in api.items(path, {"limit": 200}))

    if linked():
        return
    api.request(path, method="POST", payload={"data": [{"type": "builds", "id": build_id}]})
    for attempt in range(6):
        if linked():
            return
        if attempt < 5:
            time.sleep(5)
    raise RuntimeError("App Store Connect did not confirm the beta group assignment")


def distribute(api, version, number, distribution, processing_timeout=DEFAULT_PROCESSING_TIMEOUT):
    deadline = time.monotonic() + processing_timeout
    groups = find_groups(api, distribution)
    build_id, store_version = wait_for_build(api, version, number, deadline)
    external = distribution == "mobile-testers"
    state_key = "externalBuildState" if external else "internalBuildState"
    allowed_states = EXTERNAL_STATES if external else TESTING_STATES
    detail = wait_for_beta_detail(api, build_id, state_key, deadline)
    state = detail["attributes"][state_key]
    if state not in allowed_states:
        raise RuntimeError(f"TestFlight build {version} ({number}) cannot be distributed: {state}")

    submit_review = (
        external and state == "READY_FOR_BETA_SUBMISSION"
        and wait_for_review_slot(api, build_id, store_version, deadline)
    )
    if external and not detail["attributes"].get("autoNotifyEnabled"):
        api.request(f"/v1/buildBetaDetails/{detail['id']}", method="PATCH", payload={
            "data": {"type": "buildBetaDetails", "id": detail["id"],
                     "attributes": {"autoNotifyEnabled": True}},
        })
    if submit_review:
        submission = api.request("/v1/betaAppReviewSubmissions", method="POST", payload={
            "data": {"type": "betaAppReviewSubmissions", "relationships": {
                "build": {"data": {"type": "builds", "id": build_id}},
            }},
        })["data"]
        print(f"Submitted Beta App Review: {submission['attributes']['betaReviewState']}.", flush=True)

    for group in groups:
        attach_build(api, group, build_id)
    # Assignment can finish after the processing deadline. Give the status read its own budget.
    final_detail = wait_for_beta_detail(api, build_id, state_key, time.monotonic() + 30)
    state = final_detail["attributes"][state_key]
    if state not in allowed_states:
        raise RuntimeError(f"TestFlight build {version} ({number}) changed to {state}")
    return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--distribution", choices=["mobile-testers", "internal"], required=True)
    parser.add_argument("--processing-timeout", type=int, default=DEFAULT_PROCESSING_TIMEOUT,
                        help="Seconds to wait for build processing and an available beta review slot")
    args = parser.parse_args()
    if args.processing_timeout <= 0:
        parser.error("--processing-timeout must be positive")

    try:
        version, number = read_report(args.report, args.source_revision)
        api = AppStoreConnect(
            os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"], os.environ["ASC_KEY"],
        )
        state = distribute(api, version, number, args.distribution, args.processing_timeout)
    except (KeyError, OSError, RuntimeError, ValueError) as error:
        raise SystemExit(str(error)) from error
    audience = "Mobile Testers" if args.distribution == "mobile-testers" else "internal TestFlight groups"
    print(f"iOS {version} ({number}) assigned to {audience}. TestFlight status: {state}.")


if __name__ == "__main__":
    main()
