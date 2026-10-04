# vm-local-stt: a NixOS switch must not cut a dictation.
#
# 2026-10-04 the deploy of a change to the four local-stt units ran
# `switch-to-configuration`, whose user-unit pass stopped the router and the
# three whisper servers and started them again while a dictation was in
# flight. The router died on SIGTERM with the request in hand, its port was
# closed for half a second, and the dictation was lost.
#
# This lane boots the units tuxedo deploys (modules/nixos/local-stt.nix; the
# whisper servers swapped for stubs, never a model) under a real user manager
# and runs the real switch-to-configuration into a generation whose four unit
# files differ, with a transcription in flight. What must hold:
#
#   - the transcription in flight returns 200 with its text, although its
#     backend was restarted under it (the router sends the audio again);
#   - a request that arrives while the router is between its old and its new
#     process waits on the socket and is answered, not refused;
#   - the switch itself succeeds, and afterwards the new router and the new
#     backends are the ones running (new code takes effect, no manual step);
#   - negative control: a router run the way it ran before (binds its own
#     port, no drain) loses its in-flight request and refuses the one that
#     arrives during the switch, so the cases above do span the restart;
#   - switching to a generation where the router binds its own port and back
#     to the socket-activated one leaves a working endpoint each time (the
#     first deploy of the socket, and a rollback across it).
#
# The same user manager also runs the dictation corpus keeper
# (modules/nixos/stt-corpus.nix) against a stand-in for Voquill's database
# and audio folder: a new recording starts it, the timer catches a clip no
# file event announced, a row that lands after its file still arrives, and
# the cap drops the oldest. (What one run does to the corpus is covered
# without a VM in tests/stt-corpus.nix.)
#
# The stubs hold a request for as long as <log>.hold exists, so "in flight"
# and "during the restart" are facts the test arranges, not timing.
#
# Run: nix build .#checks.x86_64-linux.vm-local-stt -L
{ pkgs, inputs }:
let
  inherit (import ./lib/local-stt-fixtures.nix { inherit pkgs; }) stub client;
  inherit (import ./lib/stt-corpus-fixtures.nix { inherit pkgs; }) voquill;
  dir = "/tmp/stt";
  sttUnits = [ "local-stt" "local-stt-general" "local-stt-general-short" "local-stt-swedish" ];
in
(import ./lib/common.nix { inherit pkgs inputs; }).mkMinimalTest {
  name = "vm-local-stt";
  extraModules = [
    ../modules/nixos/local-stt.nix
    ../modules/nixos/stt-corpus.nix
    ({ lib, pkgs, config, ... }:
      let
        # A whisper server replaced by the stub: the unit keeps everything
        # else the module gives it (restart behaviour, priority, ordering).
        stubbed = port: name: {
          unitConfig.ConditionPathExists = lib.mkForce [ ];
          serviceConfig.ExecStart = lib.mkForce
            "${pkgs.python3}/bin/python3 ${stub} ${toString port} ${name} ${dir}/asked.${name}";
        };
        router = config.systemd.user.services.local-stt;
      in
      {
        # The one option of ai-throttle.nix the router's unit reads; the
        # governor itself has no part in this lane.
        options.services.aiThrottle.foregroundHint = lib.mkOption {
          type = lib.types.str;
          default = "%t/ai-throttle/foreground-hint";
        };

        config = {
          system.switch.enable = true;
          users.users.jonathan.linger = true;
          environment.systemPackages = [ pkgs.python3 pkgs.jq ];
          systemd.tmpfiles.rules = [ "d ${dir} 0777 root root -" ];

          # The corpus keeper with a cap and a sweep small enough to watch.
          services.sttCorpus = {
            maxClips = 3;
            sweepInterval = "5s";
          };

          systemd.user.services = {
            local-stt-general = stubbed 8763 "general";
            local-stt-general-short = stubbed 8762 "short";
            local-stt-swedish = stubbed 8764 "swedish";
            # Negative control: the same router program the way it ran before
            # 2026-10-04, binding its own port, stopped and started by the
            # switch, and with no chance to finish what it holds.
            local-stt-unprotected = {
              description = "negative control: a router without the deploy protections";
              wantedBy = [ "default.target" ];
              environment = router.environment // { LOCAL_STT_PORT = "8799"; };
              serviceConfig = {
                ExecStart = router.serviceConfig.ExecStart;
                KillSignal = "SIGKILL";
              };
            };
          };

          specialisation = {
            # A deploy that changes all four unit files, like the one that cut
            # the dictation, and the control's too.
            redeploy.configuration.systemd.user.services =
              lib.genAttrs (sttUnits ++ [ "local-stt-unprotected" ])
                (_: { environment.DEPLOY_GENERATION = "2"; });
            # The router the way it was deployed before the socket: it binds
            # the port itself and is stopped and started by a switch. The
            # socket unit has to be absent, as it was, not masked
            # (`enable = false`): switch-to-configuration takes a masked
            # socket for one it should start. `config` here is this node's
            # own: the other user sockets (dbus) are packaged units this
            # option only pulls into sockets.target, and that is kept.
            legacy.configuration = {
              systemd.user.sockets = lib.mkForce (lib.mapAttrs (_: socket: { inherit (socket) wantedBy; })
                (removeAttrs config.systemd.user.sockets [ "local-stt" ]));
              systemd.user.services = lib.genAttrs sttUnits (_: { stopIfChanged = lib.mkForce true; }) // {
                local-stt = {
                  stopIfChanged = lib.mkForce true;
                  requires = lib.mkForce [ ];
                };
              };
            };
          };
        };
      })
  ];
  testScript = ''
    import json
    import time

    dellan.wait_for_unit("multi-user.target")
    uid = dellan.succeed("id -u jonathan").strip()
    dellan.wait_for_unit(f"user@{uid}.service")

    def user(cmd):
        return dellan.succeed(f"su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/{uid} {cmd}'")

    def prop(unit, name):
        return user(f"systemctl --user show -P {name} {unit}").strip()

    def exists(path):
        return dellan.execute(f"test -e {path}")[0] == 0

    def ask(port, token, patience=30):
        return json.loads(dellan.succeed(
            f"LOCAL_STT_TEST_PORT={port} LOCAL_STT_TEST_TIMEOUT={patience} python3 ${client} {token}"))

    def ask_in_background(port, token, out):
        # The answer appears at `out` only once it is complete.
        dellan.succeed(
            f"(LOCAL_STT_TEST_PORT={port} LOCAL_STT_TEST_TIMEOUT=600 python3 ${client} {token} "
            f"> {out}.part 2>&1 < /dev/null; mv {out}.part {out}) > /dev/null 2>&1 &")

    def answer(path):
        return json.loads(dellan.succeed(f"cat {path}"))

    def asked(name, token):
        return int(dellan.succeed(
            f"if [ -f ${dir}/asked.{name} ]; then grep -c {token} ${dir}/asked.{name} || true; else echo 0; fi").strip())

    def wait_for(what, condition, seconds=180):
        for _ in range(seconds * 5):
            if condition():
                return
            time.sleep(0.2)
        raise Exception(f"timed out waiting for {what}")

    def switch_log():
        return dellan.succeed("cat ${dir}/switch.log 2>/dev/null || true")

    def switch_to(toplevel):
        out = dellan.succeed(f"{toplevel}/bin/switch-to-configuration test 2>&1")
        print(f"[diag] switch to {toplevel}:\n{out}")

    for port in (8762, 8763, 8764, 8766, 8799):
        dellan.wait_for_open_port(port)

    with subtest("the router answers through the stubs"):
        res = ask(8766, "EN-hello")
        assert res == [200, {"text": "general heard it"}], res
        res = ask(8799, "EN-hello")
        assert res == [200, {"text": "general heard it"}], res

    with subtest("a switch that changes all four units does not cut a dictation"):
        router_before = prop("local-stt.service", "MainPID")
        general_before = prop("local-stt-general.service", "MainPID")
        socket_since = prop("local-stt.socket", "ActiveEnterTimestampMonotonic")
        print(f"[diag] before: router {router_before}, general {general_before}, socket since {socket_since}")

        # One transcription in flight through the router, one through the control.
        dellan.succeed("touch ${dir}/asked.general.hold")
        ask_in_background(8766, "EN-inflight", "${dir}/inflight.json")
        ask_in_background(8799, "EN-control", "${dir}/control.json")
        wait_for("both requests to reach the general model",
                 lambda: asked("general", "EN-inflight") >= 1 and asked("general", "EN-control") >= 1)

        dellan.succeed(
            "(/run/booted-system/specialisation/redeploy/bin/switch-to-configuration test "
            "> ${dir}/switch.log 2>&1 < /dev/null; echo $? > ${dir}/switch.rc.part; "
            "mv ${dir}/switch.rc.part ${dir}/switch.rc) > /dev/null 2>&1 &")

        # The general model is restarted under the request; the router, told
        # to stop, keeps the request and sends the audio to the new process.
        def resent():
            if exists("${dir}/inflight.json"):
                raise Exception(
                    "the switch cut the transcription in flight: "
                    + dellan.succeed("cat ${dir}/inflight.json") + "\n" + switch_log())
            return asked("general", "EN-inflight") >= 2
        wait_for("the audio in flight to be sent to the restarted general model", resent)

        # Negative control: the unprotected router was stopped with its
        # request in hand, and its port is closed while the switch runs.
        wait_for("the control's caller to get its answer", lambda: exists("${dir}/control.json"))
        control = answer("${dir}/control.json")
        assert control[0] != 200, f"negative control: the unprotected router kept its request: {control}"
        refused = ask(8799, "EN-control-window", patience=5)
        assert refused[0] == 599, f"negative control: the unprotected port answered during the switch: {refused}"

        # The window: the old router is finishing, no new one runs yet. A
        # dictation that ends now waits on the socket.
        ask_in_background(8766, "EN-window", "${dir}/window.json")
        time.sleep(2)
        assert not exists("${dir}/inflight.json"), "the held request was answered before its backend let go"
        assert not exists("${dir}/window.json"), (
            "a request sent during the restart got an answer before the new router ran: "
            + dellan.succeed("cat ${dir}/window.json"))
        assert not exists("${dir}/switch.rc"), (
            "the switch finished although the router still held a request:\n" + switch_log())

        dellan.succeed("rm ${dir}/asked.general.hold")
        wait_for("the switch to finish", lambda: exists("${dir}/switch.rc"))
        print("[diag] switch output:\n" + switch_log())
        rc = dellan.succeed("cat ${dir}/switch.rc").strip()
        assert rc == "0", f"switch-to-configuration exited {rc}:\n{switch_log()}"

        wait_for("the two answers", lambda: exists("${dir}/inflight.json") and exists("${dir}/window.json"), 60)
        inflight = answer("${dir}/inflight.json")
        assert inflight == [200, {"text": "general heard it"}], (
            f"the transcription in flight across the switch: {inflight}")
        window = answer("${dir}/window.json")
        assert window == [200, {"text": "general heard it"}], (
            f"the request that arrived during the restart: {window}")

        # New code is in effect without anyone restarting anything by hand.
        router_after = prop("local-stt.service", "MainPID")
        assert router_after not in ("0", router_before), (router_before, router_after)
        assert prop("local-stt-general.service", "MainPID") not in ("0", general_before)
        environ = dellan.succeed(f"tr '\\0' '\\n' < /proc/{router_after}/environ")
        assert "DEPLOY_GENERATION=2" in environ, f"the running router is not the new generation's:\n{environ}"
        # The port never closed: the socket unit was not touched.
        assert prop("local-stt.socket", "ActiveEnterTimestampMonotonic") == socket_since, (
            "the listening socket was restarted by the switch")
        dellan.wait_for_open_port(8799)

    with subtest("to a router that binds its own port, and back to the socket"):
        switch_to("/run/booted-system/specialisation/legacy")
        wait_for("the legacy router to answer",
                 lambda: dellan.execute("LOCAL_STT_TEST_PORT=8766 LOCAL_STT_TEST_TIMEOUT=5 python3 ${client} models")[0] == 0, 60)
        res = ask(8766, "EN-legacy")
        assert res == [200, {"text": "general heard it"}], res
        state = user("systemctl --user is-active local-stt.socket || true").strip()
        assert state != "active", f"the legacy generation still has the socket: {state}"

        # The first deploy of the socket: the old process holds the port until
        # it is stopped, and the socket has to bind it before the new one starts.
        switch_to("/run/booted-system")
        wait_for("the socket-activated router to answer",
                 lambda: dellan.execute("LOCAL_STT_TEST_PORT=8766 LOCAL_STT_TEST_TIMEOUT=5 python3 ${client} models")[0] == 0, 60)
        res = ask(8766, "EN-back")
        assert res == [200, {"text": "general heard it"}], res
        assert prop("local-stt.socket", "ActiveState") == "active", "the socket did not come up"
        assert prop("local-stt.socket", "SubState") == "running", (
            "the router is not running off the socket: " + prop("local-stt.socket", "SubState"))
        assert prop("local-stt.service", "ActiveState") == "active"

    with subtest("the corpus keeper is started by a new recording and by its timer"):
        home = "/home/jonathan"
        corpus = f"{home}/.local/share/stt-corpus"
        database = f"{home}/.config/com.voquill.desktop.local/voquill.db"
        fixture = (
            f"FAKE_VOQUILL_DB={database} "
            f"FAKE_VOQUILL_AUDIO={home}/.local/share/com.voquill.desktop.local/transcription-audio "
            "python3 ${voquill}")

        def kept():
            return dellan.succeed(
                f"if [ -f {corpus}/voquill-manifest.jsonl ]; then jq -r .id {corpus}/voquill-manifest.jsonl | tr '\\n' ' '; fi"
            ).strip()

        problems = []

        def expect(what, ids, seconds):
            try:
                wait_for(what, lambda: kept() == ids, seconds)
            except Exception:
                problems.append(f"{what}: the corpus has [{kept()}], expected [{ids}]")

        # The file event alone (timer stopped): the row is there when the
        # recording lands, so the run it starts finds the clip.
        user("systemctl --user stop stt-corpus-keep.timer")
        user(f"{fixture} init")
        user(f"{fixture} add clip-a 1000 rowfirst")
        expect("a new recording to start the keeper", "clip-a", 30)

        # The timer alone (path unit stopped): nothing announces this clip.
        user("systemctl --user stop stt-corpus-keep.path")
        user(f"{fixture} add clip-b 2000")
        user("systemctl --user start stt-corpus-keep.timer")
        expect("the timer to sweep a clip no event announced", "clip-a clip-b", 60)

        # Both, and the order the app writes in: the recording first, its
        # row a moment later. The event comes too early; the clip arrives.
        user("systemctl --user start stt-corpus-keep.path")
        user(f"{fixture} add clip-c 3000 rowlate")
        expect("a clip whose row came after its file", "clip-a clip-b clip-c", 60)

        # The cap (3 here): the oldest goes, file and line.
        user(f"{fixture} add clip-d 4000 rowfirst")
        expect("the cap to drop the oldest clip", "clip-b clip-c clip-d", 60)
        if exists(f"{corpus}/voquill/clip-a.wav"):
            problems.append("the dropped clip's file is still in the corpus")

        # A burst: several short dictations in a row (or history being
        # cleared) start the keeper many times within seconds. systemd's
        # default start limit (5 starts in 10 s) would fail the service and
        # take the path unit down with it until the next login. The timer is
        # stopped, so only the file events can bring these clips in.
        user("systemctl --user stop stt-corpus-keep.timer")
        for n in range(8):
            user(f"{fixture} add burst-{n} {5000 + n} rowfirst")
            dellan.succeed("sleep 0.5")
        expect("every clip of a burst of recordings", "burst-5 burst-6 burst-7", 30)
        path_state = prop("stt-corpus-keep.path", "ActiveState")
        path_result = prop("stt-corpus-keep.path", "Result")
        if path_state != "active":
            problems.append(
                f"after a burst of recordings the path unit is {path_state} (Result={path_result}), not active")
        dellan.execute(
            f"su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/{uid} systemctl --user start stt-corpus-keep.timer'")

        # No database (Voquill not installed yet, or its folder moved): the
        # unit still ends well, and the corpus stays as it is.
        dellan.succeed(f"mv {database} {database}.away")
        status, _ = dellan.execute(
            f"su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/{uid} systemctl --user start stt-corpus-keep.service'")
        result = prop("stt-corpus-keep.service", "Result")
        if status != 0 or result != "success":
            problems.append(f"without a database the keeper failed (start exited {status}, Result={result})")
        if kept() != "burst-5 burst-6 burst-7":
            problems.append(f"without a database the corpus changed: [{kept()}]")
        dellan.succeed(f"mv {database}.away {database}")

        mode = dellan.succeed(f"stat -c %a {corpus}").strip()
        if mode != "700":
            problems.append(f"the corpus folder has mode {mode}, not 700")
        assert not problems, "\n".join(problems)
  '';
}
