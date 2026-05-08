import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class gavsRacePacerApp extends Application.AppBase {

    private var mView as gavsRacePacerView? = null;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
    }

    function onStop(state as Dictionary?) as Void {
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        mView = new gavsRacePacerView();
        return [mView as WatchUi.Views];
    }

    function onSettingsChanged() as Void {
        if (mView != null) {
            (mView as gavsRacePacerView).loadSettings();
        }
        WatchUi.requestUpdate();
    }

}

function getApp() as gavsRacePacerApp {
    return Application.getApp() as gavsRacePacerApp;
}
