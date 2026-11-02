#!/usr/bin/env python3
"""Stock lab CLI with Touch Sample's larger SD-card builder installed."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "vendor/virtual-mpc-sample"))
import lab
import sample_card

sample_card.install(lab)

if __name__ == "__main__":
    lab.main()
