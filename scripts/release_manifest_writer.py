#!/usr/bin/env python3
# Copyright 2026 MetastudyLine. All rights reserved.
# SPDX-License-Identifier: MIT OR Apache-2.0

"""Release manifest builder for TTZip deterministic 3-channel Bazel packaging."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple


def sha256_file(path: Optional[str]) -> Optional[str]:
    if not path or not os.path.isfile(path):
        return None
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _parse_dirty_status_tokens(
    tokens: List[bytes], workspace_dir: str
) -> Tuple[Dict[str, Optional[str]], List[str]]:
    dirty_files_sha256: Dict[str, Optional[str]] = {}
    filtered_status_lines: List[str] = []
    idx = 0
    while idx < len(tokens):
        tok = tokens[idx]
        if not tok:
            idx += 1
            continue
        status_xy = tok[:2].decode("utf-8", errors="replace")
        raw_rel = tok[3:].decode("utf-8")
        orig_rel = None
        if status_xy[0] in ("R", "C") or status_xy[1] in ("R", "C"):
            idx += 1
            if idx < len(tokens) and tokens[idx]:
                orig_rel = tokens[idx].decode("utf-8")
        idx += 1
        if raw_rel.startswith("products/ttzip/apple/dist/"):
            continue
        line = f"{status_xy} {orig_rel} -> {raw_rel}" if orig_rel is not None else f"{status_xy} {raw_rel}"
        filtered_status_lines.append(line)
        full_path = os.path.join(workspace_dir, raw_rel)
        if os.path.islink(full_path):
            dirty_files_sha256[raw_rel] = "symlink:" + os.readlink(full_path)
        elif os.path.isfile(full_path):
            dirty_files_sha256[raw_rel] = sha256_file(full_path)
        elif not os.path.exists(full_path):
            dirty_files_sha256[raw_rel] = "deleted"
    return dirty_files_sha256, filtered_status_lines


def collect_source_snapshot(
    workspace_dir: str,
) -> Tuple[str, Dict[str, Any], List[str], Dict[str, Optional[str]]]:
    git_head = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=workspace_dir, text=True
    ).strip()
    git_diff_bytes = subprocess.check_output(
        ["git", "diff", "HEAD", "--binary"], cwd=workspace_dir
    )
    git_diff_sha256 = hashlib.sha256(git_diff_bytes).hexdigest()
    git_status_z = subprocess.check_output(
        ["git", "status", "--porcelain", "-z", "-uall"], cwd=workspace_dir
    )
    dirty_files_sha256, filtered_status_lines = _parse_dirty_status_tokens(
        git_status_z.split(b"\x00"), workspace_dir
    )
    composite_snapshot_sha256 = hashlib.sha256(
        json.dumps(
            {
                "git_head_commit": git_head,
                "git_diff_head_sha256": git_diff_sha256,
                "dirty_files_sha256": dirty_files_sha256,
            },
            sort_keys=True,
        ).encode("utf-8")
    ).hexdigest()
    snapshot = {
        "git_head_commit": git_head,
        "git_diff_head_sha256": git_diff_sha256,
        "composite_snapshot_sha256": composite_snapshot_sha256,
        "dirty_files_sha256": dirty_files_sha256,
    }
    return git_head, snapshot, filtered_status_lines, dirty_files_sha256


def inspect_codesign(target: str) -> Dict[str, Any]:
    proc = subprocess.run(
        ["codesign", "-dvvv", target], capture_output=True, text=True, check=False
    )
    output = (proc.stdout or "") + "\n" + (proc.stderr or "")
    info: Dict[str, Any] = {
        "cdhash": None,
        "signature": None,
        "authority": [],
        "team_identifier": None,
        "timestamp": None,
    }
    scalar_prefixes = {
        "CDHash=": "cdhash",
        "Signature=": "signature",
        "TeamIdentifier=": "team_identifier",
        "Timestamp=": "timestamp",
    }
    for raw_line in output.splitlines():
        if raw_line.startswith("Authority="):
            info["authority"].append(raw_line.split("=", 1)[1].strip())
            continue
        for prefix, key in scalar_prefixes.items():
            if raw_line.startswith(prefix):
                info[key] = raw_line.split("=", 1)[1].strip()
                break
    return info


def collect_bundle_hashes(
    app_dir: str,
) -> Tuple[Dict[str, Any], Dict[str, Optional[str]], Dict[str, Optional[str]]]:
    main_sign = inspect_codesign(app_dir)
    signing_components = {
        "TTZip": app_dir,
        "ttarchive-worker": os.path.join(app_dir, "Contents/Helpers/ttarchive-worker"),
        "TTMediaWorker.xpc": os.path.join(app_dir, "Contents/XPCServices/TTMediaWorker.xpc"),
        "TTZipFinderSync.appex": os.path.join(app_dir, "Contents/PlugIns/TTZipFinderSync.appex"),
        "TTZipQuickLook.appex": os.path.join(app_dir, "Contents/PlugIns/TTZipQuickLook.appex"),
    }
    executables = {
        "TTZip": os.path.join(app_dir, "Contents/MacOS/TTZip"),
        "ttarchive-worker": os.path.join(app_dir, "Contents/Helpers/ttarchive-worker"),
        "TTMediaWorker": os.path.join(
            app_dir, "Contents/XPCServices/TTMediaWorker.xpc/Contents/MacOS/TTMediaWorker"
        ),
        "TTZipFinderSync": os.path.join(
            app_dir, "Contents/PlugIns/TTZipFinderSync.appex/Contents/MacOS/TTZipFinderSync"
        ),
        "TTZipQuickLook": os.path.join(
            app_dir, "Contents/PlugIns/TTZipQuickLook.appex/Contents/MacOS/TTZipQuickLook"
        ),
    }
    llamacpp_dylib_path = os.path.join(app_dir, "Contents/Frameworks/libllamacpp.dylib")
    if os.path.isfile(llamacpp_dylib_path):
        signing_components["libllamacpp.dylib"] = llamacpp_dylib_path
        executables["libllamacpp.dylib"] = llamacpp_dylib_path
    components_cdhash = {
        name: inspect_codesign(path)["cdhash"] for name, path in signing_components.items()
    }
    executables_sha256 = {k: sha256_file(v) for k, v in executables.items()}
    return main_sign, components_cdhash, executables_sha256


def build_baseline_and_remediation(
    baseline_manifest_path: str,
    manifest_path: str,
    dirty_files_sha256: Dict[str, Optional[str]],
    remediation_manifest_path: str,
) -> Tuple[Optional[Dict[str, Any]], Optional[Dict[str, Any]]]:
    if (
        not baseline_manifest_path
        or not os.path.isfile(baseline_manifest_path)
        or os.path.abspath(baseline_manifest_path) == os.path.abspath(manifest_path)
    ):
        return None, None
    with open(baseline_manifest_path, "r", encoding="utf-8") as f:
        base_m = json.load(f)
    base_snap = base_m.get("source_snapshot", {})
    base_dirty = base_snap.get("dirty_files_sha256", {})
    base_comp = base_snap.get("composite_snapshot_sha256") or hashlib.sha256(
        json.dumps(
            {
                "git_head_commit": base_snap.get("git_head_commit"),
                "git_diff_head_sha256": base_snap.get("git_diff_head_sha256"),
                "dirty_files_sha256": base_dirty,
            },
            sort_keys=True,
        ).encode("utf-8")
    ).hexdigest()
    previous_baseline = {
        "manifest_path": os.path.abspath(baseline_manifest_path),
        "manifest_sha256": sha256_file(baseline_manifest_path),
        "archive_path": base_m.get("archive_path"),
        "archive_sha256": base_m.get("archive_sha256"),
        "bazel_raw_archive_sha256": base_m.get("bazel_raw_archive_sha256"),
        "mas_pkg_path": base_m.get("mas_pkg_path"),
        "mas_pkg_sha256": base_m.get("mas_pkg_sha256"),
        "executables_sha256": base_m.get("executables_sha256"),
        "signing_type": base_m.get("signing", {}).get("signing_type"),
        "components_cdhash": base_m.get("signing", {}).get("components_cdhash"),
        "timestamp": base_m.get("signing", {}).get("timestamp"),
        "composite_snapshot_sha256": base_comp,
    }
    changed_files = {
        rel_p: {
            "baseline_sha256": base_dirty.get(rel_p),
            "candidate_sha256": dirty_files_sha256.get(rel_p),
        }
        for rel_p in sorted(set(base_dirty) | set(dirty_files_sha256))
        if base_dirty.get(rel_p) != dirty_files_sha256.get(rel_p)
    }
    ttzip_changed = {
        k: v
        for k, v in changed_files.items()
        if k.startswith(("products/ttzip/", "infra/ttmedia/", "infra/ttlog/", "infra/ttkit/"))
    }
    remediation_items = []
    if remediation_manifest_path and os.path.isfile(remediation_manifest_path):
        with open(remediation_manifest_path, "r", encoding="utf-8") as rf:
            remediation_items = json.load(rf)
    remediation_lineage = {
        "changed_files_since_baseline_count": len(changed_files),
        "ttzip_changed_files_since_baseline_count": len(ttzip_changed),
        "ttzip_changed_files_since_baseline": ttzip_changed,
        "changed_files_since_baseline": changed_files,
        "remediation_items": remediation_items,
    }
    return previous_baseline, remediation_lineage


def run_probe(cmd: List[str]) -> Dict[str, Any]:
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    combined = ((proc.stdout or "") + (proc.stderr or "")).strip()
    return {
        "command": " ".join(cmd),
        "exit_code": proc.returncode,
        "output": combined,
    }


def _run_offline_cms_verify(workspace_dir: str, app_dir: str) -> Dict[str, Any]:
    proc = subprocess.run(
        [
            sys.executable,
            os.path.join(workspace_dir, "products/ttzip/apple/scripts/provision_profile_tool.py"),
            "--mode",
            "verify-cms-offline",
            "--apple-dir",
            os.path.join(workspace_dir, "products/ttzip/apple"),
            "--app-bundle",
            app_dir,
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(proc.stdout)


def collect_signing_section(
    workspace_dir: str,
    app_dir: str,
    requested_identity: str,
    profiles_json_path: str,
    main_sign: Dict[str, Any],
    components_cdhash: Dict[str, Optional[str]],
) -> Dict[str, Any]:
    embedded_profiles = None
    if profiles_json_path and os.path.isfile(profiles_json_path):
        with open(profiles_json_path, "r", encoding="utf-8") as f:
            embedded_profiles = json.load(f)
    strict_verify_probe = run_probe(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app_dir]
    )
    seatbelt_repro_probe = run_probe(
        [
            "/usr/bin/sandbox-exec",
            "-p",
            '(version 1)(allow default)(deny mach-lookup (global-name "com.apple.trustd") (global-name "com.apple.trustd.agent"))',
            "/usr/bin/codesign",
            "--verify",
            "--deep",
            "--strict",
            "--verbose=2",
            app_dir,
        ]
    )
    spctl_probe = run_probe(
        ["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=4", app_dir]
    )
    stapler_probe = run_probe(["/usr/bin/xcrun", "stapler", "validate", app_dir])

    signing_type_val = "ad-hoc" if main_sign["signature"] == "adhoc" else "certificate"
    is_stapled = stapler_probe["exit_code"] == 0
    if signing_type_val == "ad-hoc":
        channel_gate_status = "internal_functional_acceptance_only_not_for_release"
    elif strict_verify_probe["exit_code"] == 0 and is_stapled and spctl_probe["exit_code"] == 0:
        channel_gate_status = "signed_and_notarized_ready"
    elif strict_verify_probe["exit_code"] == 0:
        channel_gate_status = "strict_codesign_verified_pending_notarization_and_spctl"
    else:
        channel_gate_status = "pending_trusted_host_strict_codesign_and_notarization"

    offline_cms = _run_offline_cms_verify(workspace_dir, app_dir)
    return {
        "requested_identity": requested_identity,
        "signing_type": signing_type_val,
        "channel_release_gate_status": channel_gate_status,
        "authority": main_sign["authority"],
        "team_identifier": main_sign["team_identifier"],
        "timestamp": main_sign["timestamp"],
        "components_cdhash": components_cdhash,
        "embedded_profiles": embedded_profiles,
        "strict_codesign_verify": {
            **strict_verify_probe,
            "trusted_host_verified": (strict_verify_probe["exit_code"] == 0),
        },
        "seatbelt_trustd_denied_repro": {
            **seatbelt_repro_probe,
            "role": "diagnostic_reproduction_evidence_only",
            "counts_as_channel_pass": False,
        },
        "system_policy_assessment_spctl": {
            **spctl_probe,
            "status": "accepted" if spctl_probe["exit_code"] == 0 else "rejected_or_unnotarized",
        },
        "notarization_and_stapling": {
            **stapler_probe,
            "stapled": is_stapled,
            "status": "stapled" if is_stapled else "not_notarized",
        },
        "offline_cms_verification": offline_cms,
    }


def write_release_manifest(argv: List[str]) -> None:
    (
        manifest_path,
        channel,
        short_ver,
        build_ver,
        build_cmd,
        signed_zip_path,
        raw_zip_path,
        app_dir,
        workspace_dir,
        requested_identity,
        profiles_json_path,
        pkg_path,
        candidate_id,
        baseline_manifest_path,
        remediation_manifest_path,
        bazel_output_base,
        build_config,
    ) = argv[1:18]

    git_head, source_snapshot, filtered_status_lines, dirty_files_sha256 = (
        collect_source_snapshot(workspace_dir)
    )
    main_sign, components_cdhash, executables_sha256 = collect_bundle_hashes(app_dir)
    previous_baseline, remediation_lineage = build_baseline_and_remediation(
        baseline_manifest_path, manifest_path, dirty_files_sha256, remediation_manifest_path
    )
    signing_section = collect_signing_section(
        workspace_dir,
        app_dir,
        requested_identity,
        profiles_json_path,
        main_sign,
        components_cdhash,
    )
    has_pkg = bool(pkg_path and os.path.isfile(pkg_path))
    manifest = {
        "candidate_id": candidate_id if candidate_id else "baseline",
        "channel": channel,
        "version": short_ver,
        "build_version": build_ver,
        "build_command": build_cmd,
        "build_config": build_config,
        "bazel_output_base": (
            os.path.abspath(bazel_output_base)
            if bazel_output_base
            else "default_workspace_output_base"
        ),
        "archive_path": os.path.abspath(signed_zip_path),
        "archive_sha256": sha256_file(signed_zip_path),
        "bazel_raw_archive_path": os.path.abspath(raw_zip_path),
        "bazel_raw_archive_sha256": sha256_file(raw_zip_path),
        "app_bundle_path": os.path.abspath(app_dir),
        "mas_pkg_path": os.path.abspath(pkg_path) if has_pkg else None,
        "mas_pkg_sha256": sha256_file(pkg_path) if has_pkg else None,
        "executables_sha256": executables_sha256,
        "signing": signing_section,
        "previous_baseline": previous_baseline,
        "remediation_lineage": remediation_lineage,
        "source_snapshot": source_snapshot,
        "git_commit": git_head,
        "git_dirty_files": filtered_status_lines,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
    }
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, sort_keys=True, ensure_ascii=False)
        f.write("\n")


if __name__ == "__main__":
    write_release_manifest(sys.argv)
