#include "TelemetryWsRelay.h"

#include <QWebSocket>
#include <QWebSocketServer>
#include <QHostAddress>

TelemetryWsRelay::TelemetryWsRelay(QObject *parent)
    : QObject(parent)
{
}

TelemetryWsRelay::~TelemetryWsRelay()
{
    stopServer();
}

bool TelemetryWsRelay::startServer(quint16 port)
{
    if (serverRunning()) {
        return true;
    }

    if (_server) {
        // previous instance in weird state
        _server->close();
        _server->deleteLater();
        _server = nullptr;
    }

    _server = new QWebSocketServer(
        QStringLiteral("PX4-Telemetry-Relay"),
        QWebSocketServer::NonSecureMode,
        this);

    if (!_server->listen(QHostAddress::LocalHost, port)) {
        emit errorOccurred(tr("WS relay: bind port %1 failed (%2)")
                               .arg(port)
                               .arg(_server->errorString()));
        delete _server;
        _server = nullptr;
        return false;
    }

    _port = port;
    connect(_server, &QWebSocketServer::newConnection,
            this, &TelemetryWsRelay::_onNewConnection);

    emit serverRunningChanged();
    return true;
}

void TelemetryWsRelay::stopServer()
{
    if (!_server) {
        return;
    }

    for (auto *client : _clients) {
        client->close();
        client->deleteLater();
    }
    _clients.clear();

    _server->close();
    _server->deleteLater();
    _server = nullptr;
    _port = 0;

    emit serverRunningChanged();
    emit clientCountChanged();
}

void TelemetryWsRelay::broadcast(const QString &jsonPayload)
{
    if (!_server || _clients.isEmpty()) {
        return;
    }
    if (jsonPayload.isEmpty()) {
        return;
    }

    const QByteArray data = jsonPayload.toUtf8();
    for (auto *client : _clients) {
        if (client->state() == QAbstractSocket::ConnectedState) {
            client->sendTextMessage(data);
        }
    }
}

void TelemetryWsRelay::_onNewConnection()
{
    Q_ASSERT(_server);
    while (_server->hasPendingConnections()) {
        QWebSocket *client = _server->nextPendingConnection();
        _clients.append(client);
        connect(client, &QWebSocket::disconnected,
                this, &TelemetryWsRelay::_onClientDisconnected);
    }
    emit clientCountChanged();
}

void TelemetryWsRelay::_onClientDisconnected()
{
    auto *client = qobject_cast<QWebSocket*>(sender());
    if (!client) {
        return;
    }
    _clients.removeAll(client);
    client->deleteLater();
    emit clientCountChanged();
}
