#!/bin/bash
# Author: william2003[at]gmail[dot]com
#	  duonglt[at]engr[dot]ucsb[dot]edu
# Date: 09/30/2008
#
# Custom Shell script to clone Virtual Machines for Labs at UCSB ResNet for ESXi, script will take number of agruments based on a golden image along with
# designated virtual machine lab name and a range of VMs to be created.
#######################################################################################################################################################

ESXI_VMWARE_VIM_CMD=/bin/vim-cmd

printUCSB() {
        echo "######################################################"
        echo "#"
        echo "# UCSB ResNet Linked Clones Tool for ESXi"
        echo "# Author: william2003[at]gmail[dot]com"
        echo -e "# \t  duonglt[at]engr[dot]ucsb[dot]edu"
        echo "# Created: 09/30/2008"
        echo "#"
        echo "######################################################"
}

validateUserInput() {
	#sanity check to make sure you're executing on an ESX 3.x host
	if [ ! -f ${ESXI_VMWARE_VIM_CMD} ]; then
       		echo "This script is meant to be executed on VMware ESXi, please try again ...."
        	exit 1
	fi
	if [ "${DEVEL_MODE}" -eq 1 ]; then echo "ESX Version valid (3.x+)"; fi

	if ! echo ${GOLDEN_VM} | egrep -i '[0-9A-Za-z]+.vmx$' > /dev/null && [[ ! -f "${GOLDEN_VM}"  ]]; then
                echo "Error: Golden VM Input is not valid"
                exit 1
        fi

        if [ "${DEVEL_MODE}" -eq 1 ]; then echo -e "\n############# SANITY CHECK START #############\n\nGolden VM .vmx file exists"; fi

	#sanity check to verify Golden VM is offline before duplicating
	${ESXI_VMWARE_VIM_CMD} vmsvc/get.runtime ${GOLDEN_VM_VMID} | grep -i "powerState" | grep -i "poweredOff" > /dev/null 2>&1
	if [ ! $? -eq 0 ]; then
        	echo "Master VM status is currently online, not registered or does not exist, please try again..."
        	exit 1
	fi
        if [ "${DEVEL_MODE}" -eq 1 ]; then echo "Golden VM is offline"; fi

        local mastervm_dir=$(dirname "${GOLDEN_VM}")
        if ls "${mastervm_dir}" | grep -iE '(delta|-rdm.vmdk|-rdmp.vmdk)' > /dev/null 2>&1; then
                echo "Master VM contains either a Snapshot or Raw Device Mapping, please ensure those are gone and please try again..."
                exit 1
        fi
        if [ "${DEVEL_MODE}" -eq 1 ]; then echo "Snapshots and RDMs were not found"; fi

        if ! grep -i "ethernet0.present = \"true\"" "${GOLDEN_VM}" > /dev/null 2>&1; then
                echo "Master VM does not contain valid eth0 vnic, script requires eth0 to be present and valid, please try again..."
                exit 1
        fi
        if [ "${DEVEL_MODE}" -eq 1 ]; then echo "eth0 found and is valid"; fi

	vmdks_count=`grep -i scsi "${GOLDEN_VM}" | grep -i fileName | awk -F "\"" '{print $2}' | wc -l`
        vmdks=`grep -i scsi "${GOLDEN_VM}" | grep -i fileName | awk -F "\"" '{print $2}'`
        if [ "${vmdks_count}" -gt 1 ]; then echo "Found more than 1 VMDK associated with the Master VM, script only supports a single VMDK, please unattach the others and try again..."; exit 1; fi
        if [ "${DEVEL_MODE}" -eq 1 ]; then echo "Single VMDK disk found"; fi

        if ! echo ${START_COUNT} | egrep '^[0-9]+$' > /dev/null; then
                echo "Error: START value is not valid"
                exit 1
        fi
        if [ "${DEVEL_MODE}" -eq 1 ]; then echo "START parameter is valid"; fi

        if ! echo ${END_COUNT} | egrep '^[0-9]+$' > /dev/null; then
                echo "Error: END value is not valid"
                exit 1
        fi
        if [ "${DEVEL_MODE}" -eq 1 ]; then echo "END parameter is valid"; fi

        #sanity check to verify your range is positive
        if [ "${START_COUNT}" -gt "${END_COUNT}" ]; then
                echo "Your Start Count can not be greater or equal to your End Count, please try again..."
                exit 1
        fi
        if [ "${DEVEL_MODE}" -eq 1 ]; then echo "START and END range is valid"; fi

        #end of sanity check
        if [ "${DEVEL_MODE}" -eq 1 ]; then echo -e "\n########### SANITY CHECK COMPLETE ############";exit; fi
}

#sanity check on the # of args
if [ $# != 4 ]; then
	printUCSB
        echo -e "\nUsage: `basename $0` [FULL_PATH_TO_MASTER_VMX_FILE] [VM_NAME] [START_#] [END_#]"
        echo -e "\ti.e."
        echo -e "\t\t$0 /vmfs/volumes/4857f047-4e4ec6bf-a8b8-001b78361a3c/LabMaster/LabMaster.vmx LabClient- 1 200"
        echo -e "\tOutput:"
        echo -e "\t\tLabClient-{1-200}"
        exit 1
fi

#DO NOT TOUCH INTERNAL VARIABLES
#set variables
GOLDEN_VM=$1
VM_NAMING_CONVENTION=$2
START_COUNT=$3
END_COUNT=$4

GOLDEN_VM_PATH=`echo ${GOLDEN_VM%%.vmx*}`
GOLDEN_VM_NAME=`grep -i "displayName" ${GOLDEN_VM} | awk '{print $3}' | sed 's/"//g'`
GOLDEN_VM_VMID=`${ESXI_VMWARE_VIM_CMD} vmsvc/getallvms | grep -i ${GOLDEN_VM_NAME} | awk '{print $1}'`
STORAGE_PATH=`echo ${GOLDEN_VM%/*/*}`

validateUserInput

#print out user configuration - requires user input to verify the configs before duplication
while true;
do
        echo -e "Requested parameters:"
        echo -e "\tMaster Virtual Machine Image: $GOLDEN_VM"
        echo -e "\tLinked Clones output: $VM_NAMING_CONVENTION{$START_COUNT-$END_COUNT}"
        echo
        echo "Would you like to continue with these configuration y/n?"
        read userConfirm
        case $userConfirm in
                yes|YES|y|Y)
                        echo "Cloning will proceed for $VM_NAMING_CONVENTION{$START_COUNT-$END_COUNT}"
                        echo
                        break;;
                no|NO|n|N)
                        echo "Requested parameters canceled, application exiting"
                        exit;;
        esac
done

#start duplication
COUNT=$START_COUNT
MAX=$END_COUNT
START_TIME=`date`
S_TIME=`date +%s`
TOTAL_VM_CREATE=$(( ${END_COUNT} - ${START_COUNT} + 1 ))

LC_EXECUTION_DIR=/tmp/esxi_linked_clones_run.$$
mkdir -p ${LC_EXECUTION_DIR}
LC_CREATED_VMS=${LC_EXECUTION_DIR}/newly_created_vms.$$
touch ${LC_CREATED_VMS}

WATCH_FILE=${LC_CREATED_VMS}
EXPECTED_LINES=${TOTAL_VM_CREATE}

while sleep 5;
do
	REAL_LINES=$(wc -l < "${WATCH_FILE}")
	REAL_LINES=`echo ${REAL_LINES} | sed 's/^[ \t]*//;s/[ \t]*$//'`
	P_RATIO=$(( (${REAL_LINES} * 100 ) / ${EXPECTED_LINES} ))
	P_RATIO=${P_RATIO%%.*}
	clear
	echo -en "\r${P_RATIO}% Complete! - Linked Clones Created: ${REAL_LINES}/${EXPECTED_LINES}"
	if [ ${REAL_LINES} -ge ${EXPECTED_LINES} ]; then
		break
	fi
done &

while [ "$COUNT" -le "$MAX" ];
do
        FINAL_VM_NAME="${VM_NAMING_CONVENTION}${COUNT}"
        mkdir -p ${STORAGE_PATH}/$FINAL_VM_NAME

        cp ${GOLDEN_VM_PATH}.vmx ${STORAGE_PATH}/$FINAL_VM_NAME/$FINAL_VM_NAME.vmx

	VMDK_PATH=`grep -i scsi0:0.fileName ${GOLDEN_VM_PATH}.vmx | awk '{print $3}' | sed 's/"//g'`
	sed -i 's/displayName = "'${GOLDEN_VM_NAME}'"/displayName = "'${FINAL_VM_NAME}'"/' ${STORAGE_PATH}/$FINAL_VM_NAME/$FINAL_VM_NAME.vmx
        sed -i '/scsi0:0.fileName/d' ${STORAGE_PATH}/$FINAL_VM_NAME/$FINAL_VM_NAME.vmx
        echo "scsi0:0.fileName = \"${STORAGE_PATH}/${GOLDEN_VM_NAME}/${VMDK_PATH}\"" >> ${STORAGE_PATH}/$FINAL_VM_NAME/$FINAL_VM_NAME.vmx
	sed -i 's/nvram = "'${GOLDEN_VM_NAME}.nvram'"/nvram = "'${FINAL_VM_NAME}.nvram'"/' ${STORAGE_PATH}/$FINAL_VM_NAME/$FINAL_VM_NAME.vmx
	sed -i 's/extendedConfigFile = "'${GOLDEN_VM_NAME}.vmxf'"/extendedConfigFile = "'${FINAL_VM_NAME}.vmxf'"/' ${STORAGE_PATH}/$FINAL_VM_NAME/$FINAL_VM_NAME.vmx
        sed -i '/ethernet0.generatedAddress/d' ${STORAGE_PATH}/$FINAL_VM_NAME/$FINAL_VM_NAME.vmx > /dev/null 2>&1
	sed -i '/ethernet0.addressType/d' ${STORAGE_PATH}/$FINAL_VM_NAME/$FINAL_VM_NAME.vmx > /dev/null 2>&1
        sed -i '/uuid.location/d' ${STORAGE_PATH}/$FINAL_VM_NAME/$FINAL_VM_NAME.vmx > /dev/null 2>&1
        sed -i '/uuid.bios/d' ${STORAGE_PATH}/$FINAL_VM_NAME/$FINAL_VM_NAME.vmx > /dev/null 2>&1
	sed -i '/sched.swap.derivedName/d' ${STORAGE_PATH}/$FINAL_VM_NAME/$FINAL_VM_NAME.vmx > /dev/null 2>&1

        ${ESXI_VMWARE_VIM_CMD} solo/registervm ${STORAGE_PATH}/$FINAL_VM_NAME/$FINAL_VM_NAME.vmx > /dev/null 2>&1

	FINAL_VM_VMID=`${ESXI_VMWARE_VIM_CMD} vmsvc/getallvms | grep -i ${FINAL_VM_NAME} | awk '{print $1}'`

        ${ESXI_VMWARE_VIM_CMD} vmsvc/snapshot.create ${FINAL_VM_VMID} Cloned ${FINAL_VM_NAME}_Cloned_from_${GOLDEN_VM_NAME} > /dev/null 2>&1

        #output to file to later use
        echo "${STORAGE_PATH}/$FINAL_VM_NAME/$FINAL_VM_NAME.vmx" >> "${LC_CREATED_VMS}"

        COUNT=$(( $COUNT + 1 ))
done

sleep 10
echo -e "\n\nWaiting for Virtual Machine(s) to obtain MAC addresses...\n"

END_TIME=`date`
E_TIME=`date +%s`

#grab mac addresses of newly created VMs (file to populate dhcp static config)
if [ -f ${LC_CREATED_VMS} ]; then
        for i in `cat ${LC_CREATED_VMS}`;
        do
		TMP_LIST=${LC_EXECUTION_DIR}/vm_list.$$
                VM_P=`echo ${i##*/}`
                VM_NAME=`echo ${VM_P%.vmx*}`
                VM_MAC=`grep -i ethernet0.generatedAddress "${i}" | awk '{print $3}' | sed 's/\"//g' | head -1 | sed 's/://g'`
		while [ "${VM_MAC}" == "" ]
		do
			sleep 1
			VM_MAC=`grep -i ethernet0.generatedAddress "${i}" | awk '{print $3}' | sed 's/\"//g' | head -1 | sed 's/://g'`
		done
                echo "${VM_NAME}  ${VM_MAC}" >> ${TMP_LIST}
        done
        LCS_OUTPUT="lcs_created_on-`date +%F-%H%M%S`"
        echo -e "Linked clones VM MAC addresses stored at:"
        cat ${TMP_LIST} | sed 's/[[:digit:]]/ &/1' | sort -k2n | sed 's/ //1' > "${LCS_OUTPUT}"
        echo -e "\t${LCS_OUTPUT}"
fi

echo
echo "Start time: ${START_TIME}"
echo "End   time: ${END_TIME}"
DURATION=`echo $((E_TIME - S_TIME))`

#calculate overall completion time
if [ ${DURATION} -le 60 ]; then
        echo "Duration  : ${DURATION} Seconds"
else
        echo "Duration  : `awk 'BEGIN{ printf "%.2f\n", '${DURATION}'/60}'` Minutes"
fi
echo
rm -rf ${LC_EXECUTION_DIR}
