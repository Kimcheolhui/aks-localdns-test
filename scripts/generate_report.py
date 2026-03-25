#!/usr/bin/env python3
"""
실험 결과 마크다운 리포트 생성.

사용법:
  python3 scripts/generate_report.py

results/summary.json 을 읽어서 experiment-result.md 를 생성한다.
"""

import json
import sys
from pathlib import Path

METRICS = [
    ("latency_avg_ms", "Avg Latency (ms)"),
    ("latency_min_ms", "Min Latency (ms)"),
    ("latency_max_ms", "Max Latency (ms)"),
    ("latency_p50_ms", "P50 Latency (ms)"),
    ("latency_p95_ms", "P95 Latency (ms)"),
    ("latency_p99_ms", "P99 Latency (ms)"),
    ("total_queries", "Total Queries"),
    ("qps_total", "Total QPS"),
]

COMPARISON_METRICS = [
    ("latency_avg_ms", "Avg Latency (ms)"),
    ("latency_min_ms", "Min Latency (ms)"),
    ("latency_max_ms", "Max Latency (ms)"),
    ("latency_p50_ms", "P50 Latency (ms)"),
    ("latency_p95_ms", "P95 Latency (ms)"),
    ("latency_p99_ms", "P99 Latency (ms)"),
]


def load_summary() -> dict:
    summary_path = Path("results/summary.json")
    if not summary_path.exists():
        print("Error: results/summary.json not found. Run collect_summary.py first.")
        sys.exit(1)
    with open(summary_path) as f:
        return json.load(f)


def avg_runs(runs: list[dict], key: str) -> float:
    values = [r.get(key, 0) for r in runs]
    return sum(values) / len(values) if values else 0


def fmt(value) -> str:
    if isinstance(value, float):
        if abs(value) >= 1000:
            return f"{value:,.0f}"
        if abs(value) >= 1:
            return f"{value:.2f}"
        return f"{value:.4f}"
    if isinstance(value, int):
        return f"{value:,}"
    return str(value)


def calc_diff(b_val, l_val) -> str:
    if b_val == 0:
        return "-"
    diff_pct = (l_val - b_val) / b_val * 100
    sign = "+" if diff_pct > 0 else ""
    return f"{sign}{diff_pct:.1f}%"


def get_qps_labels(data: dict) -> list[str]:
    """qps-20, qps-40, ... 에서 숫자만 추출하여 정렬."""
    labels = []
    for key in data:
        num = int(key.replace("qps-", ""))
        labels.append(num)
    return sorted(labels)


def build_phase_table(data: dict, phase: str, qps_list: list[int]) -> str:
    header = "| 지표 | " + " | ".join(f"QPS {q}" for q in qps_list) + " |"
    separator = "|------|" + "|".join("------:" for _ in qps_list) + "|"

    rows = [header, separator]
    for key, label in METRICS:
        values = []
        for q in qps_list:
            runs = data.get(f"qps-{q}", {}).get(phase, [])
            if runs:
                values.append(fmt(avg_runs(runs, key)))
            else:
                values.append("-")
        rows.append(f"| {label} | " + " | ".join(values) + " |")

    return "\n".join(rows)


def build_comparison_table(data: dict, qps_list: list[int]) -> str:
    # 열: QPS 조건, 행: 지표별 Baseline / LocalDNS / 변화
    header = "| Pod 당 QPS | " + " | ".join(label for _, label in COMPARISON_METRICS) + " |"
    separator = "|------|" + "|".join("------:" for _ in COMPARISON_METRICS) + "|"

    rows = [header, separator]
    for q in qps_list:
        b_runs = data.get(f"qps-{q}", {}).get("baseline", [])
        l_runs = data.get(f"qps-{q}", {}).get("localdns", [])

        # Baseline 행
        b_cells = [f"| **{q}** - Baseline |"]
        l_cells = [f"| **{q}** - LocalDNS |"]
        d_cells = [f"| **{q}** - 변화량 |"]
        for key, _ in COMPARISON_METRICS:
            if b_runs and l_runs:
                b_val = avg_runs(b_runs, key)
                l_val = avg_runs(l_runs, key)
                diff = calc_diff(b_val, l_val)
                b_cells.append(f" {fmt(b_val)} |")
                l_cells.append(f" {fmt(l_val)} |")
                d_cells.append(f" **{diff}** |")
            else:
                b_cells.append(" - |")
                l_cells.append(" - |")
                d_cells.append(" - |")
        rows.append("".join(b_cells))
        rows.append("".join(l_cells))
        rows.append("".join(d_cells))
        # QPS 간 구분선
        if q != qps_list[-1]:
            rows.append("|" + "|".join(" " for _ in range(len(COMPARISON_METRICS) + 1)) + "|")

    return "\n".join(rows)


def main():
    data = load_summary()
    qps_list = get_qps_labels(data)

    lines = [
        "# AKS LocalDNS 실험 결과",
        "",
        f"> 250 Pod × QPS {', '.join(str(q) for q in qps_list)} | 5회 시행 평균",
        "",
        "---",
        "",
        "## Baseline (LocalDNS OFF)",
        "",
        build_phase_table(data, "baseline", qps_list),
        "",
        "---",
        "",
        "## LocalDNS ON",
        "",
        build_phase_table(data, "localdns", qps_list),
        "",
        "---",
        "",
        "## Baseline vs LocalDNS 비교",
        "",
        build_comparison_table(data, qps_list),
        "",
    ]

    output = "\n".join(lines)
    output_path = Path("experiment-result.md")
    output_path.write_text(output)

    print(output)
    print(f"\nSaved to {output_path}")


if __name__ == "__main__":
    main()
