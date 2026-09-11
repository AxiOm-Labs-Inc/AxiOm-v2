package app.axiom;

interface IServiceCallback {
  void onServiceStatusChanged(int status);
  void onServiceAlert(int type, String message);
  void onServiceWriteLog(String message);
  void onServiceResetLogs(in List<String> messages);
}