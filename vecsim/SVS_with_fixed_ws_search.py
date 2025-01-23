import json
import os
import pandas as pd
from openpyxl import load_workbook
from openpyxl.styles import PatternFill

paths = []
path = os.getcwd()
files = [f for f in os.listdir(path) if os.path.isfile(os.path.join(path, f))]
settings = {}
results = []
for file in files:
    if "upload" in file:
        with open(os.path.join(path, file)) as f:
            data = json.load(f)
            experiment_name = data["params"]["experiment"]
            configuration = {}
            configuration["num_threads"] = data["params"]["svs_config"]["NUM_THREADS"] 
            configuration["graph_degree"] = data["params"]["svs_config"]["GRAPH_DEGREE"] 
            configuration["ws_construction"] = data["params"]["svs_config"]["WS_CONSTRUCTION"] 
            configuration["quantization"] = data["params"]["svs_config"]["QUANTIZATION"]
            configuration["uploading_time"] = data["results"]["total_time"]
            configuration["used_memory"] = data["results"]["memory_usage"]["used_memory"][0]
            settings[experiment_name] = configuration
for file in files:
    if not "upload" in file:
        with open(os.path.join(path, file)) as f:
            data = json.load(f)
            result = {}
            experiment_name = data["params"]["experiment"]
            result["parallel"] = data["params"]["parallel"]
            result["total_time"] = data["results"]["total_time"]
            result["mean_time"] = data["results"]["mean_time"]
            result["precision"] = data["results"]["mean_precisions"]
            result["rps"] = data["results"]["rps"]
            result["ws_search"] = data["params"]["search_params"]["WS_SEARCH"]
            result["num_threads"] = settings[experiment_name]["num_threads"]
            result["graph_degree"] = settings[experiment_name]["graph_degree"]
            result["ws_construction"] = settings[experiment_name]["ws_construction"]
            result["quantization"] = settings[experiment_name]["quantization"]
            results.append(result)

result_json_path = os.path.join(path, "summary/results.json")
with open(result_json_path, "w") as f:
    json.dump(results, f)


df = pd.DataFrame(results)

idx = df.groupby(['parallel', 'ws_search', 'graph_degree', 'num_threads', 'quantization', 'ws_construction'])['rps'].idxmax()
df_max_rps = df.loc[idx]

df_total_time = df_max_rps.pivot(index=['parallel', 'ws_search'], columns=['graph_degree', 'num_threads', 'quantization', 'ws_construction'], values='total_time')
df_mean_time = df_max_rps.pivot(index=['parallel', 'ws_search'], columns=['graph_degree', 'num_threads', 'quantization', 'ws_construction'], values='mean_time')
df_precision = df_max_rps.pivot(index=['parallel', 'ws_search'], columns=['graph_degree', 'num_threads', 'quantization', 'ws_construction'], values='precision')
df_rps = df_max_rps.pivot(index=['parallel', 'ws_search'], columns=['graph_degree', 'num_threads', 'quantization', 'ws_construction', ], values='rps')

df_uploading_time = pd.DataFrame.from_dict(settings, orient='index')[['uploading_time']]
df_used_memory = pd.DataFrame.from_dict(settings, orient='index')[['used_memory']]

excel_path = "summary/results.xlsx"
with pd.ExcelWriter(excel_path) as writer:
    df_total_time.to_excel(writer, sheet_name="Total Time")
    df_mean_time.to_excel(writer, sheet_name="Mean Time")
    df_precision.to_excel(writer, sheet_name="Precision")
    df_rps.to_excel(writer, sheet_name="RPS")
    df_uploading_time.to_excel(writer, sheet_name="Uploading Time")
    df_used_memory.to_excel(writer, sheet_name="Used Memory")

wb = load_workbook(excel_path)
fill_green = PatternFill(start_color="00FF00", end_color="00FF00", fill_type="solid")

def highlight_cells(ws, top_n, reverse=False):
    values = []
    for row in ws.iter_rows(min_row=6, min_col=3):
        for cell in row:
            try:
                cell_value = float(cell.value)
                values.append((cell_value, cell))
            except (TypeError, ValueError):
                continue
    values.sort(key=lambda x: x[0], reverse=reverse)
    for i in range(min(top_n, len(values))):
        values[i][1].fill = fill_green

for sheet_name in ["Total Time", "Mean Time"]:
    ws = wb[sheet_name]
    highlight_cells(ws, top_n=3, reverse=False)
    ws.column_dimensions['B'].width = 20

for sheet_name in ["Precision", "RPS"]:
    ws = wb[sheet_name]
    highlight_cells(ws, top_n=3, reverse=True)
    ws.column_dimensions['B'].width = 20 

for sheet_name in ["Uploading Time", "Used Memory"]:
    ws = wb[sheet_name]
    ws.column_dimensions['A'].width = 40 
    ws.column_dimensions['B'].width = 20
    min_value = None
    min_cell = None
    for row in ws.iter_rows(min_row=2, min_col=2):
        for cell in row:
            try:
                cell_value = float(cell.value)
                if min_value is None or cell_value < min_value:
                    min_value = cell_value
                    min_cell = cell
            except (TypeError, ValueError):
                continue
    if min_cell:
        min_cell.fill = fill_green

wb.save(excel_path)