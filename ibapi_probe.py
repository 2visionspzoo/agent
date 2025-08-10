from ibapi.client import EClient
from ibapi.wrapper import EWrapper
import threading, time, sys
class App(EWrapper, EClient):
    def __init__(self): EClient.__init__(self, self)
    def error(self, reqId, code, msg, *_): print("error:", reqId, code, msg)
    def nextValidId(self, orderId): print("nextValidId:", orderId)
app = App()
try:
    host, port, client = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    app.connect(host, port, client)
    threading.Thread(target=app.run, daemon=True).start()
    for _ in range(15):
        print("isConnected:", app.isConnected()); time.sleep(1)
    app.disconnect()
except Exception as e:
    print("connect_exception:", e)
