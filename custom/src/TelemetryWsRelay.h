#ifndef TELEMETRY_WS_RELAY_H
#define TELEMETRY_WS_RELAY_H

#include <QObject>
#include <QWebSocketServer>
#include <QWebSocket>
#include <QList>

/// Telemetry WebSocket broadcaster for Route-B (Unity external window).
/// Read-only: consumes the schema v1 JSON produced by TelemetrySnapshot.js
/// (QML side), broadcasts to all connected WS clients at 10 Hz.
///
/// This class ONLY owns the WS server and connected sockets. It does NOT
/// touch Vehicle facts directly - the QML side builds the payload so there
/// is exactly one source of truth for schema v1 (TelemetrySnapshot.js).
///
/// Endpoint: ws://127.0.0.1:19390/telemetry
/// Protocol: text frames, each one a complete schema v1 JSON object.
///
/// Threading: single-thread, lives in the QML engine thread. QWebSocketServer
/// accepts on the default event loop. No locks needed.
class TelemetryWsRelay : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool serverRunning READ serverRunning NOTIFY serverRunningChanged)
    Q_PROPERTY(quint16 port READ port NOTIFY serverRunningChanged)
    Q_PROPERTY(int clientCount READ clientCount NOTIFY clientCountChanged)

public:
    explicit TelemetryWsRelay(QObject *parent = nullptr);
    ~TelemetryWsRelay() override;

    bool serverRunning() const { return _server != nullptr && _server->isListening(); }
    quint16 port() const { return _port; }
    int clientCount() const { return _clients.count(); }

    Q_INVOKABLE bool startServer(quint16 port = 19390);
    Q_INVOKABLE void stopServer();

    /// Broadcast one schema v1 JSON frame to every connected client.
    /// Called from QML Timer tick (100 ms). Empty / invalid strings are ignored.
    Q_INVOKABLE void broadcast(const QString &jsonPayload);

signals:
    void serverRunningChanged();
    void clientCountChanged();
    void errorOccurred(const QString &message);

private slots:
    void _onNewConnection();
    void _onClientDisconnected();

private:
    QWebSocketServer *_server{nullptr};
    QList<QWebSocket*> _clients;
    quint16 _port{0};
};

#endif // TELEMETRY_WS_RELAY_H
