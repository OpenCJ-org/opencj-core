"""Run pool integration and VM regressions in the disposable #192 fixture."""
from pathlib import Path
import runpy
runpy.run_path(str(Path(__file__).with_name("run-history-save-192.py")),
              init_globals={"SQL_ADAPTER_VERIFY": True}, run_name="__main__")
