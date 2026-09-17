#!/usr/bin/env python3
"""hermes-digest.py — отправить суточную сводку владельцу в Telegram.

Сводку считает agents/checks/digest.sh (только измерения), здесь — доставка тем же
каналом и тем же токеном, что использует шина агентов: отдельного транспорта не заводим.

    python3 scripts/hermes-digest.py            # посчитать и отправить
    python3 scripts/hermes-digest.py --dry-run  # напечатать, не отправляя
"""
from __future__ import annotations

import os
import subprocess
import sys

REPO = os.environ.get("HERMES_HOME", "/opt/hermes")
# Так же, как scripts/hermes-alert-poller.py: корень репо (для пакета bus) и каталог bus
# (чтобы bus_bridge импортировался как модуль верхнего уровня).
sys.path.insert(0, REPO)
sys.path.insert(0, os.path.join(REPO, "bus"))


def main() -> int:
    dry = "--dry-run" in sys.argv
    try:
        body = subprocess.run(["bash", f"{REPO}/agents/checks/digest.sh"],
                              capture_output=True, text=True, timeout=300).stdout.strip()
    except Exception as e:                                    # noqa: BLE001
        print(f"digest не посчитался: {type(e).__name__}: {e}")
        return 2
    if not body:
        print("digest пуст — отправлять нечего")
        return 2
    if dry:
        print(body)
        return 0
    try:
        import bus_bridge as m                                      # type: ignore
    except Exception as e:                                    # noqa: BLE001
        print(f"нет доступа к каналу Telegram: {type(e).__name__}: {e}")
        return 2
    # Длинную сводку отправляем документом, короткую — сообщением: как и всё остальное,
    # что агент пишет владельцу.
    if len(body) > 3000:
        ref = m._stage_report(body) if hasattr(m, "_stage_report") else ""
        sent = m.tg_send_document(str(ref), "📅 Hermes за сутки")[0] if ref else False
        if not sent:
            sent = m.tg_send(body[:3000])
    else:
        sent = m.tg_send(body)
    print("отправлено" if sent else "не отправлено (канал недоступен)")
    return 0 if sent else 1


if __name__ == "__main__":
    sys.exit(main())
