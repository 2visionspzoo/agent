import os
if os.getenv("FORCE_DISABLE_CONID_SYNC","0") == "1":
    try:
        import agent.conid_sync as _cs
        def _noop(*a, **k):
            raise RuntimeError("conId sync disabled by sitecustomize")
        _cs.ensure_conids = _noop
    except Exception:
        pass
