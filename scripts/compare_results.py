#!/usr/bin/env python3
"""
Baseline vs LocalDNS 결과 비교 리포트 생성.

사용법:
  python3 scripts/compare_results.py

results/baseline/run*/summary.json 과 results/localdns/run*/summary.json 을
읽어서 마크다운 비교 테이블을 생성한다.

출력: results/comparison.md
"""

import json
import sys
from pathlib import Path

METRICS = [
    ("latency_avg_ms", "Avg Latency (ms)"),
    ("latency_min_ms", "Min Latency (ms)"),
    ("latency_max_ms", "Max Latency (ms)"),
    ("latency_stddev_ms", "StdDev Latency (ms)"),
    ("latency_p50_ms", "P50 Latency (ms)"),
    ("latency_p90_ms", "P90 Latency (ms)"),
    ("latency_p95_ms", "P95 Latency (ms)"),
    ("latency_p99_ms", "P99 Latency (ms)"),
    ("queries_sent", "Queries Sent"),
    ("queries_completed", "Queries Completed"),
    ("queries_lost", "Queries Lost"),
    ("queries_lost_pct", "Queries Lost (%)"),
    ("qps_total", "Total QPS"),
    ("pods_collected", "Pods Collected"),
    ("total_queries", "Total Queries"),
]


def load_summaries(phase: str) -> list[dict]:
    """phase 디렉토리에서 run별 summary.json을 로드."""
    phase_dir = Path("results") / phase
    summaries = []
    for run_dir in sorted(phase_dir.glob("run*")):
        summary_file = run_dir / "summary.json"
        if summary_file.exists():
            with open(summary_file) as f:
                summaries.append(json.load(f))
    return summaries


def fmt(value) -> str:
    """숫자 포맷팅."""
    if isinstance(value, float):
        if value < 1:
            return f"{value:.4f}"
        return f"{value:.2f}"
    return str(value)


def calc_diff(baseline_val, localdns_val) -> str:
    """변화율 계산."""
    if not isinstance(baseline_val, (int, float)) or not isinstance(localdns_val, (int, float)):
        return "-"
    if baseline_val == 0:
        return "-"
    diff_pct = (localdns_val - baseline_val) / baseline_val * 100
    sign = "+" if diff_pct > 0 else ""
    return f"{sign}{diff_pct:.1f}%"


def build_phase_table(summaries: list[dict]) -> str:
    """한 phase의 마크다운 테이블 생성."""
    if not summaries:
        return "No data found.\n"

    num_runs = len(summaries)
    header = f"| 지표 | " + " | ".join(f"Run {i+1}" for i in range(num_runs)) + " |"
    separator = "|------|" + "|".join("------:" for _ in range(num_runs)) + "|"

    rows = [header, separator]
    for key, label in METRICS:
        values = [fmt(s.get(key, "-")) for s in summaries]
        row = f"| {label} | " + " | ".join(values) + " |"
        rows.append(row)

    return "\n".join(rows)


def build_comparison_table(baseline: list[dict], localdns: list[dict]) -> str:
    """Baseline vs LocalDNS 평균 비교 테이블."""
    if not baseline or not localdns:
        return "데이터가 부족하여 비교할 수 없습니다.\n"

    def avg_metric(summaries, key):
        values = [s.get(key, 0) for s in summaries]
        return sum(values) / len(values) if values else 0

    header = "| 지표 | Baseline (avg) | LocalDNS (avg) | 변화 |"
    separator = "|------|------:|------:|------:|"

    rows = [header, separator]
    for key, label in METRICS:
        b_val = avg_metric(baseline, key)
        l_val = avg_metric(localdns, key)
        diff = calc_diff(b_val, l_val)
        row = f"| {label} | {fmt(b_val)} | {fmt(l_val)} | {diff} |"
        rows.append(row)

    return "\n".join(rows)


def main():
    baseline = load_summaries("baseline")
    localdns = load_summaries("localdns")

    if not baseline and not localdns:
        print("Error: No summary.json files found in results/baseline/ or results/localdns/")
        sys.exit(1)

    lines = [
        "# AKS LocalDNS 실험 결과 비교",
        "",
        "## Baseline (LocalDNS OFF)",
        "",
        build_phase_table(baseline),
        "",
        "## LocalDNS ON",
        "",
        build_phase_table(localdns),
        "",
        "## Baseline vs LocalDNS 평균 비교",
        "",
        build_comparison_table(baseline, localdns),
        "",
    ]

    output = "\n".join(lines)
    output_path = Path("experiment-result.md")
    output_path.write_text(output)

    print(output)
    print(f"\nSaved to {output_path}")


if __name__ == "__main__":
    main()
