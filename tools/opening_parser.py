from datasets import load_dataset
import json

dataset = load_dataset("Lichess/chess-openings", split="train")
dataset = dataset.remove_columns("img")

table = {}
for row in dataset:
    uci = row["uci"]
    del row["uci"]
    del	row["eco"]
    del	row["eco-volume"]
    table[uci] = row
print(json.dumps(table))
