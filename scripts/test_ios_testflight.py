import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from distribute_ios_testflight import distribute, read_report


def group(group_id, name, internal, automatic=False):
    return {"id": group_id, "attributes": {
        "name": name, "isInternalGroup": internal, "hasAccessToAllBuilds": automatic,
    }}


class FakeClock:
    def __init__(self):
        self.elapsed = 0

    def monotonic(self):
        return self.elapsed

    def sleep(self, seconds):
        self.elapsed += seconds


class FakeAppStoreConnect:
    def __init__(self):
        self.groups = [
            group("external", "Mobile testers", False),
            group("other-external", "Other external group", False),
            group("manual", "Internal team", True),
            group("automatic", "App Store Connect Users", True, automatic=True),
        ]
        self.external_state = "READY_FOR_BETA_SUBMISSION"
        self.internal_state = "READY_FOR_BETA_TESTING"
        self.auto_notify = False
        self.linked_groups = set()
        self.writes = []
        self.build_queries = []
        self.missing_build_queries = 0
        self.available_version = None
        self.beta_processing_reads = 0
        self.review_queries = []
        self.reviewing_builds = []

    def request(self, path, *, params=None, method="GET", payload=None):
        if path == "/v1/builds" and method == "GET":
            if "filter[betaAppReviewSubmission.betaReviewState]" in params:
                self.review_queries.append(params)
                builds = self.reviewing_builds.pop(0) if self.reviewing_builds else []
            else:
                self.build_queries.append(params)
                if len(self.build_queries) <= self.missing_build_queries:
                    return {"data": []}
                if self.available_version and params["filter[preReleaseVersion.version]"] != self.available_version:
                    return {"data": []}
                builds = [("MAC_OS", "MAC_OS"), ("IOS", "IOS")]
            return {
                "data": [
                    {"id": build_id, "attributes": {"processingState": "VALID", "expired": False},
                     "relationships": {"preReleaseVersion": {"data": {"id": platform + "-version"}}}}
                    for build_id, platform in builds
                ],
                "included": [
                    {"type": "preReleaseVersions", "id": platform + "-version",
                     "attributes": {"platform": platform}}
                    for platform in ("MAC_OS", "IOS")
                ],
            }
        self.writes.append((method, path, payload))
        if method == "PATCH" and path == "/v1/buildBetaDetails/detail":
            self.auto_notify = payload["data"]["attributes"]["autoNotifyEnabled"]
            return {}
        if method == "POST" and path == "/v1/betaAppReviewSubmissions":
            self.external_state = "WAITING_FOR_BETA_REVIEW"
            return {"data": {"attributes": {"betaReviewState": "WAITING_FOR_REVIEW"}}}
        if method == "POST" and path.startswith("/v1/betaGroups/"):
            self.linked_groups.add(path.split("/")[3])
            return {}
        raise AssertionError(f"Unexpected request: {method} {path}")

    def items(self, path, params=None):
        if path == "/v1/betaGroups":
            return self.groups
        if path == "/v1/buildBetaDetails":
            if params != {"filter[build]": "IOS"}:
                raise AssertionError(f"Wrong build chosen: {params}")
            processing = self.beta_processing_reads > 0
            if processing:
                self.beta_processing_reads -= 1
            return [{"id": "detail", "attributes": {
                "externalBuildState": "PROCESSING" if processing else self.external_state,
                "internalBuildState": "PROCESSING" if processing else self.internal_state,
                "autoNotifyEnabled": self.auto_notify,
            }}]
        if path.startswith("/v1/betaGroups/"):
            return [{"id": "IOS"}] if path.split("/")[3] in self.linked_groups else []
        raise AssertionError(f"Unexpected collection: {path}")


class TestFlightDistributionTests(unittest.TestCase):
    def test_verified_report_must_match_source_commit(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "ipa-verification.json"
            report.write_text(json.dumps({
                "revision": "1234abcd", "version": "3.1.0", "build": "42",
            }))
            self.assertEqual(read_report(report, "1234abcd" + "0" * 32), ("3.1.0", "42"))
            with self.assertRaisesRegex(ValueError, "does not match the built commit"):
                read_report(report, "0" * 40)

    def test_mobile_testers_submits_review_if_needed_and_can_retry(self):
        api = FakeAppStoreConnect()
        self.assertEqual(distribute(api, "3.1.0", "42", "mobile-testers"), "WAITING_FOR_BETA_REVIEW")
        self.assertEqual(api.build_queries[0]["filter[preReleaseVersion.version]"], "3.1.0")
        self.assertEqual(api.build_queries[0]["filter[version]"], "42")
        self.assertEqual(api.linked_groups, {"external"})
        self.assertTrue(api.auto_notify)
        self.assertEqual([path for _, path, _ in api.writes], [
            "/v1/buildBetaDetails/detail",
            "/v1/betaAppReviewSubmissions",
            "/v1/betaGroups/external/relationships/builds",
        ])
        review = api.writes[1][2]["data"]
        self.assertEqual(review["relationships"]["build"]["data"]["id"], "IOS")

        api.writes.clear()
        self.assertEqual(distribute(api, "3.1.0", "42", "mobile-testers"), "WAITING_FOR_BETA_REVIEW")
        self.assertEqual(api.writes, [])

    def test_internal_only_attaches_manual_internal_group_without_external_review(self):
        api = FakeAppStoreConnect()
        self.assertEqual(distribute(api, "3.1.0", "42", "internal"), "READY_FOR_BETA_TESTING")
        self.assertEqual(api.writes, [(
            "POST", "/v1/betaGroups/manual/relationships/builds",
            {"data": [{"type": "builds", "id": "IOS"}]},
        )])

    def test_waits_for_the_uploaded_build_to_appear(self):
        api = FakeAppStoreConnect()
        api.missing_build_queries = 1
        with patch("distribute_ios_testflight.time.sleep") as sleep:
            self.assertEqual(distribute(api, "3.1.1", "42", "internal"), "READY_FOR_BETA_TESTING")
        self.assertEqual(len(api.build_queries), 2)
        sleep.assert_called_once_with(10)

    def test_waits_for_beta_processing_after_binary_is_valid(self):
        for audience, expected in (("mobile-testers", "WAITING_FOR_BETA_REVIEW"),
                                   ("internal", "READY_FOR_BETA_TESTING")):
            with self.subTest(audience=audience):
                api = FakeAppStoreConnect()
                api.beta_processing_reads = 1
                with patch("distribute_ios_testflight.time.sleep") as sleep:
                    self.assertEqual(distribute(api, "3.1.1", "42", audience), expected)
                self.assertEqual(len(api.build_queries), 1)
                sleep.assert_called_once_with(10)

    def test_processing_can_take_more_than_four_minutes(self):
        api = FakeAppStoreConnect()
        api.missing_build_queries = 26
        clock = FakeClock()

        with patch("distribute_ios_testflight.time.monotonic", clock.monotonic), \
             patch("distribute_ios_testflight.time.sleep", clock.sleep):
            self.assertEqual(distribute(api, "3.1.1", "42", "internal"), "READY_FOR_BETA_TESTING")
        self.assertEqual(clock.elapsed, 260)

    def test_binary_and_beta_processing_share_the_configured_deadline(self):
        api = FakeAppStoreConnect()
        api.missing_build_queries = 1
        api.beta_processing_reads = 10
        clock = FakeClock()

        with patch("distribute_ios_testflight.time.monotonic", clock.monotonic), \
             patch("distribute_ios_testflight.time.sleep", clock.sleep):
            with self.assertRaisesRegex(TimeoutError, "beta processing did not complete"):
                distribute(api, "3.1.1", "42", "internal", processing_timeout=25)
        self.assertEqual(clock.elapsed, 25)
        self.assertEqual(api.writes, [])

    def test_matches_both_spellings_of_zero_patch_versions(self):
        for ipa_version, store_version in (("3.1.0", "3.1"), ("3.1", "3.1.0")):
            with self.subTest(ipa_version=ipa_version, store_version=store_version):
                api = FakeAppStoreConnect()
                api.available_version = store_version
                self.assertEqual(
                    distribute(api, ipa_version, "42", "mobile-testers"), "WAITING_FOR_BETA_REVIEW",
                )
                self.assertEqual(
                    [query["filter[preReleaseVersion.version]"] for query in api.build_queries],
                    [ipa_version, store_version],
                )
                self.assertEqual(api.review_queries[0]["filter[preReleaseVersion.version]"], store_version)

    def test_waits_for_another_ios_builds_review_to_clear(self):
        api = FakeAppStoreConnect()
        api.reviewing_builds = [[("older", "IOS")], [("mac-review", "MAC_OS")]]
        with patch("distribute_ios_testflight.time.sleep") as sleep:
            self.assertEqual(distribute(api, "3.1.1", "42", "mobile-testers"), "WAITING_FOR_BETA_REVIEW")
        sleep.assert_called_once_with(10)
        self.assertEqual(len(api.review_queries), 2)
        self.assertEqual(
            api.review_queries[0]["filter[betaAppReviewSubmission.betaReviewState]"],
            "WAITING_FOR_REVIEW,IN_REVIEW",
        )

    def test_does_not_resubmit_a_build_with_a_review_already_in_progress(self):
        api = FakeAppStoreConnect()
        api.reviewing_builds = [[("IOS", "IOS")]]
        distribute(api, "3.1.1", "42", "mobile-testers")
        self.assertEqual(api.linked_groups, {"external"})
        self.assertNotIn("/v1/betaAppReviewSubmissions", [path for _, path, _ in api.writes])

    def test_review_slot_timeout_leaves_release_unchanged(self):
        api = FakeAppStoreConnect()
        api.reviewing_builds = [[("older", "IOS")]]
        clock = FakeClock()
        with patch("distribute_ios_testflight.time.monotonic", clock.monotonic), \
             patch("distribute_ios_testflight.time.sleep", clock.sleep):
            with self.assertRaisesRegex(TimeoutError, "Another iOS 3.1.1 build is in Beta App Review"):
                distribute(api, "3.1.1", "42", "mobile-testers", processing_timeout=1)
        self.assertEqual(api.writes, [])

    def test_rejected_beta_build_fails_without_waiting_or_writing(self):
        api = FakeAppStoreConnect()
        api.external_state = "BETA_REJECTED"
        with patch("distribute_ios_testflight.time.sleep") as sleep:
            with self.assertRaisesRegex(RuntimeError, "BETA_REJECTED"):
                distribute(api, "3.1.1", "42", "mobile-testers")
        sleep.assert_not_called()
        self.assertEqual(api.writes, [])

    def test_missing_external_group_fails_before_writing(self):
        api = FakeAppStoreConnect()
        api.groups = [group("internal", "Mobile Testers", True)]
        with self.assertRaisesRegex(RuntimeError, "exactly one external Mobile Testers"):
            distribute(api, "3.1.0", "42", "mobile-testers")
        self.assertEqual(api.writes, [])


if __name__ == "__main__":
    unittest.main()
