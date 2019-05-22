#!/usr/bin/env bash
# Use shellcheck to check this script after making changes
# Try too keep it compatible with both GNU and BSD coreutils

# This script is for testing PulseEffects.
# Can be ran locally after making changes in code
# or in continious integration systems.
# Requirements for CI containers: bash ImageMagic scrot Xvfb
# Authors:
# - Mikhail Novosyolov <mikhailnov@dumalogiya.ru>

set -e # fail on any error
#set -f # disable globbing
#export DISPLAY=:0
# Gurantee consistency of language strings in GUIs and CLI outputs
export LANG=c

if [ "$(pwd | awk -F '/' '{print $NF}')" = "util" ]; then cd .. ; fi
dir0="$PWD"

# PulseEffects binary
# In PATH, relative or absolute
PE_BIN="${PE_BIN:-pulseeffects}"

cleanup(){
	( set +e +f
	if [ -z "$(ls -1v ${tmp_dir}/*.pid)" ]; then
		return 0
	fi
	while read -r line
	do
		kill "$line"
		# TODO: check if has been actually killed
	done < <(cat ${tmp_dir}/*.pid)
	if [ -z "$NO_CLEANUP" ] && [ -n "$tmp_dir" ]; then rm -fr ${tmp_dir:?}/* ; fi
	)
	return 0
}
export -f cleanup
trap cleanup EXIT

prepare_pulseaudio_in_container(){
	# Prepare PulseAudio in CI docker container
	# https://superuser.com/a/1223119
	pulseaudio -D --exit-idle-time=-1
	pactl load-module module-null-sink sink_name=DummyOutput sink_properties=device.description="Virtual_Dummy_Output"
	pactl load-module module-null-sink sink_name=MicOutput sink_properties=device.description="Virtual_Microphone_Output"
	pacmd set-default-source MicOutput.monitor
	pacmd set-default-sink DummyOutput
}

# This test runs a graphical app and checks that it ran OK
# The idea is described here (in Russian):
# https://lists.altlinux.org/pipermail/sisyphus/2018-April/366621.html
graphical_run_test(){
	# Xephyr is an X server in a seperate graphical window - for local tests on developer PCs
	# Xvfb is a headless X server - for automated tests
	# Let's automatically use Xephyr on developers PCs
	if [ -n "$DISPLAY" ] && [ -z "$X_SERVER" ]; then
		X_SERVER=Xephyr
	fi
	X_SERVER="${X_SERVER:-Xvfb}"

	# Keep GUI consistent to compare screenshots
	export GTK_THEME=Adwaita:light
	
	tmp_dir="$(mktemp -d)"
	mkdir -p "${tmp_dir}"
	echo "Temp dir: ${tmp_dir}"
	rm -fvr ${tmp_dir:?}/*

	virt_display="$(( ( RANDOM % 100 )  + 1 ))"
	echo "Random DISPLAY = $virt_display"
	
	case "$X_SERVER" in
		Xephyr|xephyr )
			echo "Using Xephyr X server"
			Xephyr -br -ac -noreset -screen 1024x720 ":${virt_display}" &
		;;
		Xvfb|xvfb )
			echo "Using Xvfb X server"
			Xvfb ":${virt_display}" -screen 0 1024x720x24 &
		;;
	esac
	echo $! > "${tmp_dir}/X-server.pid"
	
	# export DISPLAY only after running Xephyr, otherwise Xephyr itself tries to use this $DISPLAY
	export DISPLAY=":${virt_display}"
	
	# now run PulseEffects
	"$PE_BIN" &
	echo $! > "${tmp_dir}/pulseeffects.pid"
	
	# Check that PulseEffects started
	# TODO: improve this check
	# PulseEffects start up time is different on different systems, you make set yours
	# TODO: writee better code and avois using sleep
	SLEEP_TIME="${SLEEP_TIME:-10}"	
	sleep "$SLEEP_TIME"
	if ! ps aux | awk '{print $NF}' | grep -v 'grep ' | grep -q "${PE_BIN}\$"; then
		echo "$PE_BIN" did not start in "$SLEEP_TIME" seconds, exiting with error!
		return 1
	fi
	
	# take screenshot of our seperate X server
	scrot --quality 100 "${tmp_dir}/current_screenshot_full.png"
	
	# master screenshot of test result
	if [ "$CONTAINER" = 1 ]
		then MASTER_SCREENSHOT="${MASTER_SCREENSHOT:-${dir0}/images/master_screenshot_test.png}"
		else MASTER_SCREENSHOT="${MASTER_SCREENSHOT:-${dir0}/images/master_screenshot_test_container.png}"
	fi
	if [ ! -f "$MASTER_SCREENSHOT" ]; then
		echo "Master screenshot ${MASTER_SCREENSHOT} not found!"
		return 1
	fi
	
	# reduce number of colors in screenshot to remove unneeded artefacts and differences
	convert +dither -colors 2 "$MASTER_SCREENSHOT" "${tmp_dir}/master_screenshot_reduced.png"
	convert +dither -colors 2 "${tmp_dir}/current_screenshot_full.png" "${tmp_dir}/current_screenshot_cropped.png"
	# TODO: what will we do with different default fonts?
	
	# https://stackoverflow.com/questions/29229535/measure-similarity-of-two-images-in-java-or-imagemagick
	screenshots_diff_value="$(compare -metric ae "${tmp_dir}/master_screenshot_reduced.png" "${tmp_dir}/current_screenshot_cropped.png" null: 2>&1)"
	echo screenshots_diff_value = "$screenshots_diff_value"
	
	# 8000 is an experimanental value, probably we can somehow find a more exact value
	if [ "$screenshots_diff_value" -le 8000 ]
		then
			echo "Graphical test: OK"
			return 0
		else
			echo "Graphical test: FAILED !!!"
			return 1
	fi
	
	# trap cleanup will run if nothing else is planned to be after this function
}

while [ -n "$1" ]
do
	case "$1" in
		-x|--debug ) set -x ;;
		prepare_pulseaudio_in_container ) prepare_pulseaudio_in_container ;;
		graphical_run_test ) graphical_run_test ;;
		# TODO: default to graphical_run_test for now
		* ) graphical_run_test ;;
	esac
	shift
done
