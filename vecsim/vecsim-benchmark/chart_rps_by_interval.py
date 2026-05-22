#!/usr/bin/env python3
"""
Chart: Total RPS vs Interval for each update fraction.

Usage:
    python3 chart_rps_by_interval.py <results_dir>

Example:
    python3 chart_rps_by_interval.py mixed_workload_results_2026-05-21_09-54-07
"""

import json
import os
import sys
import glob
import matplotlib.pyplot as plt


def load_interval_stats(results_dir):
    """Load interval stats from all update_* folders in the results directory."""
    data = {}  # {fraction: [interval_stats]}

    # Find the dataset/experiment structure
    # Structure: results_dir/<dataset>/<experiment>/update_<fraction>/cluster_nodes_1/
    for update_dir in sorted(glob.glob(os.path.join(results_dir, "*", "*", "update_*", "cluster_nodes_1"))):
        # Extract the fraction from the path
        update_folder = os.path.basename(os.path.dirname(update_dir))  # update_0.1
        fraction_str = update_folder.replace("update_", "")
        try:
            fraction = float(fraction_str)
        except ValueError:
            continue

        # Find the summary JSON
        summary_files = glob.glob(os.path.join(update_dir, "*-summary.json"))
        if not summary_files:
            print(f"Warning: No summary JSON found in {update_dir}")
            continue

        with open(summary_files[0], "r") as f:
            summary = json.load(f)

        # Navigate to interval_stats
        search_data = summary.get("search", {})
        if not search_data:
            continue

        # Get first (and typically only) search result
        first_result = list(search_data.values())[0]
        results = first_result.get("results", {})
        interval_stats = results.get("interval_stats", [])

        if interval_stats:
            data[fraction] = interval_stats

    return data


def create_chart(data, output_path):
    """Create chart of total RPS vs interval for each update fraction."""
    plt.figure(figsize=(12, 7))

    for fraction in sorted(data.keys()):
        intervals = data[fraction]
        x = [s["interval"] for s in intervals]
        y = [s["total_rps"] for s in intervals]
        plt.plot(x, y, marker="o", markersize=4, label=f"update_fraction={fraction}")

    plt.xlabel("Interval", fontsize=12)
    plt.ylabel("Total RPS", fontsize=12)
    plt.title("Total RPS by Interval for Different Update Fractions", fontsize=14)
    plt.legend(fontsize=10)
    plt.grid(True, alpha=0.3)
    plt.tight_layout()

    plt.savefig(output_path, dpi=150)
    print(f"Chart saved to: {output_path}")
    plt.close()


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <results_dir>")
        sys.exit(1)

    results_dir = sys.argv[1]
    if not os.path.isdir(results_dir):
        print(f"Error: {results_dir} is not a directory")
        sys.exit(1)

    data = load_interval_stats(results_dir)
    if not data:
        print("Error: No interval stats found in the results directory.")
        sys.exit(1)

    print(f"Loaded data for {len(data)} update fractions: {sorted(data.keys())}")

    # Save chart in the results directory
    output_path = os.path.join(results_dir, "total_rps_by_interval.png")
    create_chart(data, output_path)


if __name__ == "__main__":
    main()
