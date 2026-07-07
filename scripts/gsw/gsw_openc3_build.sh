#!/bin/bash
#
# Convenience script for NOS3 development
#

CFG_BUILD_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
SCRIPT_DIR=$CFG_BUILD_DIR/../../scripts
source $SCRIPT_DIR/env.sh

###############################################################################
# Manual OpenC3 target selection
#
# Comment out targets you do NOT want loaded into OpenC3.
#
# Format:
#   TARGET_NAME mode
#
# Modes:
#   debug        -> creates TARGET_NAME_DEBUG and maps it to DEBUG interface
#   radio        -> creates TARGET_NAME_RADIO and maps it to RADIO interface
#   debug,radio  -> creates both DEBUG and RADIO aliases
#   sim_truth    -> only for SIM_42_TRUTH; creates SIM_42_TRUTH_INT interface
#
# Notes:
# - SYSTEM is intentionally not listed because OpenC3 already defines SYSTEM.
# - TO_DEBUG is treated as a standalone debug target.
# - CI_DEBUG is treated as a standalone debug target for debug mode, avoiding
#   the awkward CI_DEBUG_DEBUG alias.
# - RADIO interface is only created if at least one target uses radio mode.
###############################################################################

OPENC3_TARGET_CONFIG=$(cat <<'EOF'
# ---------------------------------------------------------------------------
# Core / cFS / NOS3 ground targets
# ---------------------------------------------------------------------------
CFS debug
PDU debug
MISSION debug
TO_DEBUG debug
CI_DEBUG debug
CMD_UTIL debug
CFDP debug
CFDP_TEST debug

# ---------------------------------------------------------------------------
# Minimal spacecraft/component targets
# ---------------------------------------------------------------------------
SAMPLE debug
GENERIC_IMU debug
GENERIC_ADCS debug
GENERIC_REACTION_WHEEL debug
MGR debug
NOVATEL_OEM615 debug
GENERIC_EPS debug



# ---------------------------------------------------------------------------
# Additional component targets
# Uncomment or change to debug,radio as needed.
# ---------------------------------------------------------------------------
# SYN debug
# GENERIC_MAG debug
# GENERIC_TORQUER debug
# GENERIC_RADIO debug
# ARDUCAM debug
# GENERIC_CSS debug
# GENERIC_THRUSTER debug
# GENERIC_FSS debug
# GENERIC_STAR_TRACKER debug
# SIM_CMDBUS_BRIDGE debug

# ---------------------------------------------------------------------------
# Radio examples
# Use these only when you want OpenC3 to create RADIO aliases/interface mappings.
# ---------------------------------------------------------------------------
# CFS debug,radio
# PDU debug,radio
# MISSION debug,radio
# SAMPLE debug,radio
# GENERIC_IMU debug,radio

# ---------------------------------------------------------------------------
# Sim truth
# Uncomment only if sim_truth_interface is enabled / needed.
# ---------------------------------------------------------------------------
# SIM_42_TRUTH sim_truth
EOF
)

###############################################################################
# Helpers
###############################################################################

declare -A OPENC3_TARGET_MODES
declare -a OPENC3_REQUESTED_TARGETS

parse_target_config() {
    while IFS= read -r raw_line
    do
        # Strip comments and trim whitespace
        line="${raw_line%%#*}"
        line=$(echo "$line" | xargs)

        if [ -z "$line" ]; then
            continue
        fi

        target=$(echo "$line" | awk '{print $1}')
        modes=$(echo "$line" | awk '{print $2}')

        if [ -z "$target" ]; then
            continue
        fi

        if [ -z "$modes" ]; then
            modes="debug"
        fi

        modes=$(echo "$modes" | tr '[:upper:]' '[:lower:]' | tr ';' ',')

        OPENC3_TARGET_MODES["$target"]="$modes"
        OPENC3_REQUESTED_TARGETS+=("$target")
    done <<< "$OPENC3_TARGET_CONFIG"
}

target_requested() {
    local target="$1"
    [[ -n "${OPENC3_TARGET_MODES[$target]+x}" ]]
}

target_has_mode() {
    local target="$1"
    local mode="$2"
    [[ ",${OPENC3_TARGET_MODES[$target]:-}," == *",$mode,"* ]]
}

copy_target_if_requested() {
    local src_dir="$1"
    local target
    target=$(basename "$src_dir")

    if [ "$target" = "SYSTEM" ]; then
        echo "Skipping SYSTEM target because OpenC3 already defines SYSTEM"
        return 0
    fi

    if ! target_requested "$target"; then
        echo "Skipping OpenC3 target $target"
        return 0
    fi

    if [ -d "$target" ]; then
        echo "Target $target already copied; skipping duplicate from $src_dir"
        return 0
    fi

    echo "Copying OpenC3 target $target"
    cp -r "$src_dir" .
    targets="$targets $target"
}

parse_target_config

# Check that local NOS3 directory exists
if [ ! -d "$USER_NOS3_DIR" ]; then
    echo ""
    echo "    Need to run make prep first!"
    echo ""
    exit 1
fi

echo "OpenC3 targets selected for this build:"
for target in "${OPENC3_REQUESTED_TARGETS[@]}"
do
    echo "  $target -> ${OPENC3_TARGET_MODES[$target]}"
done
echo ""

echo "Clone openc3-cosmos into local user directory..."
cd "$USER_NOS3_DIR"
git clone https://github.com/PinakSharmaa/cosmos-project-v7.1.0 --depth 1 -b main "$USER_NOS3_DIR/cosmos"
echo ""

echo "Prepare openc3-cosmos containers..."
cd "$OPENC3_DIR"
$OPENC3_PATH run
echo ""

echo "Waiting for OpenC3 init container to complete..."

for i in {1..180}
do
    status=$(docker inspect cosmos-openc3-cosmos-init-1 --format '{{.State.Status}}' 2>/dev/null || true)
    exit_code=$(docker inspect cosmos-openc3-cosmos-init-1 --format '{{.State.ExitCode}}' 2>/dev/null || true)

    if [ "$status" = "exited" ] && [ "$exit_code" = "0" ]; then
        echo "OpenC3 init completed successfully."
        break
    fi

    if [ "$status" = "exited" ] && [ "$exit_code" != "0" ]; then
        echo ""
        echo "ERROR: OpenC3 init failed."
        docker logs cosmos-openc3-cosmos-init-1 --tail 150
        exit 1
    fi

    if [ "$i" -eq 180 ]; then
        echo ""
        echo "ERROR: Timed out waiting for OpenC3 init to complete."
        docker logs cosmos-openc3-cosmos-init-1 --tail 150
        exit 1
    fi

    sleep 2
done

echo ""

# Start by changing to a known location
cd "$OPENC3_DIR"

# Delete any previous run info
rm -rf build
if [ -d "build" ]; then
    echo ""
    echo "ERROR: Failed to delete build directory!"
    echo ""
    exit 1
fi

# Start generating the plugin
mkdir build
cd build
$OPENC3_PATH cli generate plugin nos3
if [ ! -d "openc3-cosmos-nos3" ]; then
    echo ""
    echo "ERROR: cli generate plugin nos3 failed!"
    echo ""
    exit 1
fi

# Copy selected targets
mkdir openc3-cosmos-nos3/targets
cd openc3-cosmos-nos3/targets

targets=""

for i in $(find "$BASE_DIR/components" -name target.txt)
do
    j=$(dirname "$i")
    copy_target_if_requested "$j"
done

for i in $(find "$GSW_DIR/config/targets" -name target.txt)
do
    j=$(dirname "$i")
    copy_target_if_requested "$j"
done

# Ensure all requested targets were found, except SYSTEM which is intentionally skipped
missing_targets=""
for requested_target in "${OPENC3_REQUESTED_TARGETS[@]}"
do
    if [ "$requested_target" = "SYSTEM" ]; then
        continue
    fi

    found="false"
    for copied_target in $targets
    do
        if [ "$copied_target" = "$requested_target" ]; then
            found="true"
            break
        fi
    done

    if [ "$found" = "false" ]; then
        missing_targets="$missing_targets $requested_target"
    fi
done

if [ -n "$missing_targets" ]; then
    echo ""
    echo "ERROR: These requested OpenC3 targets were not found:"
    echo "  $missing_targets"
    echo ""
    exit 1
fi

# Apply NOS3/OpenC3 text substitutions
while IFS= read -r -d '' file
do
    sed -i -e 's/<%= CosmosCfsConfig::PROCESSOR_ENDIAN %>/LITTLE_ENDIAN/; s/<%=CF_INCOMING_PDU_MID%>/0x1800/; s/<%=CF_SPACE_TO_GND_PDU_MID%>/0x0800/;' "$file"
done < <(find . -name "*.txt" -print0)

cd ..

# Copy lib if present
if [ -d ../../lib ]; then
    cp -r ../../lib .
else
    echo "WARNING: ../../lib does not exist; skipping plugin lib copy."
fi

# Create plugin.txt
echo "Create plugin..."
rm -f plugin.txt
if [ -f "plugin.txt" ]; then
    echo ""
    echo "ERROR: Failed to remove plugin.txt file!"
    echo ""
    exit 1
fi

has_debug="false"
has_radio="false"
has_sim_truth="false"

for i in $targets
do
    if [ "$i" = "SYSTEM" ]; then
        echo "Skipping SYSTEM target because OpenC3 already defines SYSTEM"
        continue
    fi

    if [ "$i" = "SIM_42_TRUTH" ]; then
        if target_has_mode "$i" "sim_truth"; then
            echo TARGET "$i" "$i" >> plugin.txt
            has_sim_truth="true"
        else
            echo "Skipping SIM_42_TRUTH because sim_truth mode was not requested"
        fi
        continue
    fi

    if target_has_mode "$i" "debug"; then
        if [ "$i" = "TO_DEBUG" ] || [ "$i" = "CI_DEBUG" ]; then
            echo TARGET "$i" "$i" >> plugin.txt
        else
            debug="${i}_DEBUG"
            echo TARGET "$i" "$debug" >> plugin.txt
        fi
        has_debug="true"
    fi

    if target_has_mode "$i" "radio"; then
        if [ "$i" = "TO_DEBUG" ]; then
            echo "WARNING: radio mode requested for TO_DEBUG, but TO_DEBUG radio alias is not generated."
        else
            radio="${i}_RADIO"
            echo TARGET "$i" "$radio" >> plugin.txt
            has_radio="true"
        fi
    fi
done

echo "" >> plugin.txt

if [ "$has_debug" = "true" ]; then
    echo "INTERFACE DEBUG udp_interface.rb nos-fsw 5012 5013 nil nil 128 10.0 nil" >> plugin.txt

    for i in $targets
    do
        if ! target_has_mode "$i" "debug"; then
            continue
        fi

        if [ "$i" = "SYSTEM" ] || [ "$i" = "SIM_42_TRUTH" ]; then
            continue
        fi

        if [ "$i" = "TO_DEBUG" ] || [ "$i" = "CI_DEBUG" ]; then
            echo "   MAP_TARGET $i" >> plugin.txt
        else
            debug="${i}_DEBUG"
            echo "   MAP_TARGET $debug" >> plugin.txt
        fi
    done

    echo "" >> plugin.txt
fi

if [ "$has_radio" = "true" ]; then
    echo "INTERFACE RADIO udp_interface.rb radio-sim 6010 6011 nil nil 128 10.0 nil" >> plugin.txt

    for i in $targets
    do
        if ! target_has_mode "$i" "radio"; then
            continue
        fi

        if [ "$i" = "SYSTEM" ] || [ "$i" = "SIM_42_TRUTH" ] || [ "$i" = "TO_DEBUG" ]; then
            continue
        fi

        radio="${i}_RADIO"
        echo "   MAP_TARGET $radio" >> plugin.txt
    done

    echo "" >> plugin.txt
fi

if [ "$has_sim_truth" = "true" ]; then
    echo "INTERFACE SIM_42_TRUTH_INT udp_interface.rb host.docker.internal 5110 5111 nil nil 128 10.0 nil" >> plugin.txt
    echo "   MAP_TARGET SIM_42_TRUTH" >> plugin.txt
    echo "" >> plugin.txt
fi

# Capture date created
echo "" >> plugin.txt
echo "# Created on " "$DATE" >> plugin.txt
echo ""

echo "Generated plugin.txt:"
cat plugin.txt
echo ""

# Build plugin
echo "Build plugin..."
$OPENC3_PATH cli rake build VERSION=1.0.$DATE
if [ ! -f "openc3-cosmos-nos3-1.0.$DATE.gem" ]; then
    echo ""
    echo "ERROR: cli rake build failed!"
    echo ""
    exit 1
fi
echo ""

# Load plugin
echo "Load plugin..."
$OPENC3_PATH cli load openc3-cosmos-nos3-1.0.$DATE.gem
if [ $? -ne 0 ]; then
    echo ""
    echo "ERROR: Failed to load NOS3 OpenC3 plugin!"
    echo ""
    exit 1
fi
echo ""

echo "OpenC3 build script complete."
echo "Note that while this script is complete, OpenC3 may still be processing behind the scenes."
sleep 15
echo "Done sleeping, but check cpu use prior to proceeding!"
echo ""