package app.axiom;

import app.axiom.IServiceCallback;

interface IService {
  int getStatus();
  void registerCallback(in IServiceCallback callback);
  oneway void unregisterCallback(in IServiceCallback callback);
}