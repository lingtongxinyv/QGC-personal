#include "ModelRegistry.h"

#include <QtCore/QDir>
#include <QtCore/QFileInfo>
#include <QtCore/QSettings>

namespace {

const char *const kModelPathKey  = "custom/viewer3d/externalModelPath";
const char *const kModelYawKey   = "custom/viewer3d/externalYawDeg";

/// Search order matters: .glb is self contained, .gltf may need siblings and
/// is still preferred over .obj because .obj carries no material reliably.
const char *const kSupportedSuffixes[] = { "glb", "gltf", "obj" };
constexpr int kSupportedSuffixCount = 3;

bool isSupportedModel(const QString &path)
{
    const QString suffix = QFileInfo(path).suffix().toLower();
    for (int i = 0; i < kSupportedSuffixCount; ++i) {
        if (suffix == QLatin1String(kSupportedSuffixes[i])) {
            return true;
        }
    }
    return false;
}

} // namespace

ModelRegistry::ModelRegistry(QObject *parent)
    : QObject(parent)
{
    _restore();
}

QString ModelRegistry::externalUrl() const
{
    return _externalPath.isEmpty() ? QString() : QUrl::fromLocalFile(_externalPath).toString();
}

QString ModelRegistry::displayName() const
{
    return _externalPath.isEmpty() ? QStringLiteral("dji_f450") : QFileInfo(_externalPath).fileName();
}

bool ModelRegistry::selectFile(const QString &path)
{
    const QFileInfo info(path);
    if (!info.exists() || !info.isFile()) {
        _setNotice(QStringLiteral("file-missing"), QStringLiteral("warn"), path);
        return false;
    }
    if (!isSupportedModel(path)) {
        _setNotice(QStringLiteral("unsupported-format"), QStringLiteral("warn"), info.fileName());
        return false;
    }
    _applySelection(info.absoluteFilePath());
    return true;
}

bool ModelRegistry::selectFolder(const QString &path)
{
    const QFileInfo info(path);
    if (!info.exists() || !info.isDir()) {
        _setNotice(QStringLiteral("file-missing"), QStringLiteral("warn"), path);
        return false;
    }

    const QDir dir(info.absoluteFilePath());
    QString found;
    for (int i = 0; i < kSupportedSuffixCount && found.isEmpty(); ++i) {
        const QStringList matches = dir.entryList(
            { QStringLiteral("*.") + QLatin1String(kSupportedSuffixes[i]) },
            QDir::Files | QDir::Readable, QDir::Name);
        if (!matches.isEmpty()) {
            found = dir.absoluteFilePath(matches.first());
        }
    }

    if (found.isEmpty()) {
        _setNotice(QStringLiteral("folder-no-model"), QStringLiteral("warn"), dir.absolutePath());
        return false;
    }

    _applySelection(found);
    return true;
}

void ModelRegistry::resetToBuiltin()
{
    if (_externalPath.isEmpty() && _noticeCode.isEmpty()) {
        return;
    }
    _externalPath.clear();
    _externalYawDeg = 0;
    _noticeCode.clear();
    _noticeLevel.clear();
    _noticeDetail.clear();
    _persist();
    emit changed();
}

void ModelRegistry::setExternalYawDeg(int deg)
{
    int wrapped = deg % 360;
    if (wrapped < 0) {
        wrapped += 360;
    }
    if (wrapped == _externalYawDeg) {
        return;
    }
    _externalYawDeg = wrapped;
    QSettings settings;
    settings.setValue(QLatin1String(kModelYawKey), _externalYawDeg);
    emit changed();
}

void ModelRegistry::reportLoadResult(bool ok, const QString &detail)
{
    if (!ok) {
        _setNotice(QStringLiteral("load-failed"), QStringLiteral("error"), detail);
        return;
    }
    // A readable .obj carries geometry but Qt's loader degrades silently when
    // the .mtl is missing, so say so up front instead of hiding it.
    if (QFileInfo(_externalPath).suffix().compare(QLatin1String("obj"), Qt::CaseInsensitive) == 0) {
        _setNotice(QStringLiteral("obj-approximate"), QStringLiteral("info"), QString());
    } else {
        _setNotice(QString(), QString(), QString());
    }
}

void ModelRegistry::dismissNotice()
{
    _setNotice(QString(), QString(), QString());
}

void ModelRegistry::_applySelection(const QString &path)
{
    _externalPath = path;
    _noticeCode.clear();
    _noticeLevel.clear();
    _noticeDetail.clear();
    _persist();
    emit changed();
}

void ModelRegistry::_setNotice(const QString &code, const QString &level, const QString &detail)
{
    if (_noticeCode == code && _noticeLevel == level && _noticeDetail == detail) {
        return;
    }
    _noticeCode   = code;
    _noticeLevel  = level;
    _noticeDetail = detail;
    emit changed();
}

void ModelRegistry::_persist()
{
    QSettings settings;
    if (_externalPath.isEmpty()) {
        settings.remove(QLatin1String(kModelPathKey));
    } else {
        settings.setValue(QLatin1String(kModelPathKey), _externalPath);
    }
}

void ModelRegistry::_restore()
{
    QSettings settings;

    const int yaw = settings.value(QLatin1String(kModelYawKey), 0).toInt();
    _externalYawDeg = ((yaw % 360) + 360) % 360;

    const QString path = settings.value(QLatin1String(kModelPathKey)).toString();
    if (path.isEmpty()) {
        return;
    }
    const QFileInfo info(path);
    if (info.exists() && info.isFile() && isSupportedModel(path)) {
        _externalPath = info.absoluteFilePath();
    } else {
        // The remembered asset moved or was deleted: fall back to built-in
        // rather than pointing RuntimeLoader at a dead path on every start.
        settings.remove(QLatin1String(kModelPathKey));
    }
}
