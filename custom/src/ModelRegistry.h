#pragma once

#include <QObject>
#include <QString>

/// Single source of truth for the airframe model shown by every 3D view.
///
/// The registry only decides *which* asset is displayed. The actual load is
/// done in QML (RuntimeLoader inside DroneModelDjiF450.qml) and every view
/// builds and destroys its own instance, so the "independent read-only
/// consumers" rule still holds: no shared scene graph, no locks, no state
/// written back into the vehicle.
///
/// Persisted in QGC's own QSettings store (same .ini QGC uses) under
/// `custom/viewer3d/externalModelPath`. An empty value means built-in
/// dji_f450, which is also the shipping default.
///
/// Notice texts are NOT produced here: the C++ side only emits a stable ASCII
/// code plus a level, and the QML side maps the code to localized wording.
/// Keeping every literal in this file ASCII avoids the MSVC code page 936
/// mis-decoding that this project forbids in C++ sources.
class ModelRegistry : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool    isExternal   READ isExternal   NOTIFY changed)
    Q_PROPERTY(QString externalUrl  READ externalUrl  NOTIFY changed)
    Q_PROPERTY(QString displayName  READ displayName  NOTIFY changed)
    Q_PROPERTY(int     externalYawDeg READ externalYawDeg NOTIFY changed)
    Q_PROPERTY(QString noticeCode   READ noticeCode   NOTIFY changed)
    Q_PROPERTY(QString noticeLevel  READ noticeLevel  NOTIFY changed)
    Q_PROPERTY(QString noticeDetail READ noticeDetail NOTIFY changed)

public:
    explicit ModelRegistry(QObject *parent = nullptr);

    bool    isExternal()    const { return !_externalPath.isEmpty(); }
    QString externalUrl()   const;
    QString displayName()   const;
    int     externalYawDeg() const { return _externalYawDeg; }
    QString noticeCode()    const { return _noticeCode; }
    QString noticeLevel()   const { return _noticeLevel; }
    QString noticeDetail()  const { return _noticeDetail; }

    /// Accept a selected single model file (.glb / .gltf / .obj), given as an
    /// absolute local path. Returns true when the selection was taken; on
    /// refusal a notice explaining why is published.
    Q_INVOKABLE bool selectFile(const QString &path);
    /// Accept a selected folder that holds a glTF resource set. The first
    /// model file found inside (.glb > .gltf > .obj) is used.
    Q_INVOKABLE bool selectFolder(const QString &path);
    /// Drop the external selection and go back to the built-in dji_f450.
    Q_INVOKABLE void resetToBuiltin();
    /// Manual orientation trim for assets whose forward axis differs from the
    /// usual glTF convention. Value is kept in [0, 360).
    Q_INVOKABLE void setExternalYawDeg(int deg);
    /// Called once QML's RuntimeLoader has a result for the current asset.
    Q_INVOKABLE void reportLoadResult(bool ok, const QString &detail);
    Q_INVOKABLE void dismissNotice();

signals:
    void changed();

private:
    void _applySelection(const QString &path);
    void _setNotice(const QString &code, const QString &level, const QString &detail);
    void _persist();
    void _restore();

    QString _externalPath;
    int     _externalYawDeg{0};
    QString _noticeCode;
    QString _noticeLevel;
    QString _noticeDetail;
};
