#!/bin/bash --login
# version 10.2

function header(){
  fullLine=$(printf '#%.0s' $(seq 1 $(( $(tput cols) - 1)) ))
  echo -ne "${fullLine}\n\e[s${fullLine}\e[u\e[3C  $(date) : $@  \n${fullLine}\n"
}

# global variable declarations

veajor="$(awk '{print $NF}' /etc/cp-release)"
verTake="$(cpprod_util CPPROD_GetValue "CPUpdates/6.0/BUNDLE_${veajor//./_}_JUMBO_HF_MAIN" SU_Build_Take 0)"

function formatScreen(){
	if (( $1 == "1" )) 
	then 
		clear
	fi
	n="$2"
	for (( i=1 ; i<=$n ; i++ )); 
	do
	    echo
	done
}

function getPassword(){
	formatScreen "1" "3"
	echo Please enter the backup user password
	echo -----------------------------------------------------------
	read -p 'Backup User Password: ' -s userPassword1
	formatScreen "1" "3"
	echo Please verify the backup user password
	echo -----------------------------------------------------------
	read -p 'Backup User Password: ' -s userPassword2
	if [ "$userPassword1" != "$userPassword2" ]
	then
		formatScreen "1" "3"
		echo -----------------------------------------------------------
		echo passwords do not match, please retry
		sleep 2
		getPassword
	fi
}

function menu(){
clear

cat <<EOF

--------------------------------------------------------------------------------------------------------------------
This script will backup or restore your SmartEvent VM server's logs, indexes, fetchedfiles and the events database to
or from a server using SCP and SSH. 

Once this script has completed you will need to rebuild your SmartEvent VM server, re-install GAIA, Reapply DNS, NTP,
TACACS, etc. 
--------------------------------------------------------------------------------------------------------------------

PRE-PROCESSES :
Before moving forward with migrating your SmartEvent server, it is recommended that a snapshot of the
existing SmartEvent virtual machine be taken in case of fallback.
(This should be completed by your server administrators)	

Note: This procedure should be perfoed both on the server that runs the correlation unit and on the server that runs the SmartEvent.

	
EOF
	echo -----------------------------------------------------------
	echo
	PS3='Please enter your choice: '
	options=("Backup Server" "Restore Server" "Quit")
	select opt in "${options[@]}"
	do
		case $opt in
			"Backup Server")
				backupSmartEvent
				;;
			"Restore Server")
				restore
				;;
			"Quit")
				break
				;;
			*) echo "invalid option $REPLY";;
		esac
	done
}

function summary(){
	formatScreen "1" "3"
	echo please verify entries
	echo -----------------------------------------------------------
	echo backup user login: $backupUser
	echo Backup SCP server: $remoteServer
	echo local backup directory: $localDir/sesBackup
	echo remote backup directory: $remoteDir/sesBackup
	echo local output directory: $localDir/sesOutput
	echo
	echo GAIA major version: $veajor
	echo GAIA take: $verTake	
	echo
	echo
	
	while true; do
	read -p "Is this infoation correct? (y/n) " yn
	
	case $yn in 
		y ) echo ok, we will proceed;
			break;;
		n ) echo exiting...;
			backupSmartEvent;;
		* ) echo invalid response;;
	esac
	done
}

function backupSmartEvent(){
clear
cat <<EOF
BACKUPING EXSISTING SMARTEVENT SERVER :
Please reference the following SK for more infoation.

Solution Title: How to backup and restore SmartEvent log-database in R80 / R80.x 
Solution ID: sk122655 
Solution Link: https://support.checkpoint.com/results/sk/sk122655

Note: This procedure should be perfoed both on the server that runs the correlation unit and on the server that runs the SmartEvent.
	
EOF
		echo Please enter the backup userid
		echo -----------------------------------------------------------
		read -p 'Backup user name: ' backupUser
		
		getPassword
		
		formatScreen "1" "3"
		echo Please enter the backup server IP address
		echo -----------------------------------------------------------
		read -p 'Backup SCP server IP: ' remoteServer
		
		formatScreen "1" "3"
		echo Please enter the base local backup base directory \(sesBackup and output will be added to your base directory\)
		echo --------------------------------------------------------------------------------------------------------------
		read -p 'Local backup directory: ' localDirRaw
		localDir=$(echo "$localDirRaw" | sed 's:/*$::')
				
		formatScreen "1" "3"
		echo Please enter the base remote backup base directory \(sesBackup will be added to your base directory\)
		echo ----------------------------------------------------------------------------------------------------
		read -p 'Remote backup directory: ' remoteDirRaw
		remoteDir=$(echo "$remoteDirRaw" | sed 's:/*$::')
		
		summary
		
		formatScreen "1" "3"
		echo "Creating local backup directories"
		echo -----------------------------------------------------------
		mkdir -p ${localDir}/sesBackup
		mkdir -p ${localDir}/sesOutput
		cd ${localDir}/sesBackup
		
		formatScreen "1" "3"
		echo "Rotating logs"
		echo -----------------------------------------------------------

		fw logswitch > ${localDir}/sesOutput/logswitchOutput.txt
		sleep 3
		fw logswitch -audit > ${localDir}/sesOutput/logswitchAuditOutput.txt
		sleep 3
		
		formatScreen "1" "3"
		echo "Stopping services please be patient this may take a minute or two"
		echo ---------------------------------------------------------------------
		cpstop > ${localDir}/sesOutput/cpstopOutput.txt
		sleep 3
		
		formatScreen "1" "3"
		echo "Compress logs and indexes"
		echo -----------------------------------------------------------
		gtar -zcvf fw_logs.tgz $FWDIR/log/*20*.*log* > ${localDir}/sesOutput/logCompressOutput.txt
		gtar -zcvf log_indexes.tgz $RTDIR/log_indexes/*20* > ${localDir}/sesOutput/logIndexOutput.txt
		cp $INDEXERDIR/data/FetchedFiles . > ${localDir}/sesOutput/cpFetchedFilesOutput.txt
		sleep 3
		
		formatScreen "1" "3"
		echo "Running Check Point migrate_server export"
		echo -----------------------------------------------------------
		cd $FWDIR/scripts
		./migrate_server export -v ${veajor} ${localDir}/sesBackup/ses_Export.tgz
		sleep 3
		
		formatScreen "1" "3"
		echo "Creating remote backup directory on SCP server"
		echo -----------------------------------------------------------

		remotesesDir=$remoteDir'/sesBackup'
		export SSHPASS=$userPassword1
		OUTPUT2=$(sshpass -e ssh -o "StrictHostKeyChecking no" ${backupUser}@${remoteServer} 'mkdir -p '$remotesesDir)		
		unset SSHPASS
		sleep 3
		
		formatScreen "1" "3"
		echo "Check backup SCP server for disc space"
		echo -----------------------------------------------------------
		localDisc=$(du -s ${localDir})
		localDiscArray=($localDisc)
		localSpace=${localDiscArray[0]}
		echo storage space needed = $localSpace
		
		export SSHPASS=$userPassword1
		OUTPUT=$(sshpass -e ssh -o "StrictHostKeyChecking no" ${backupUser}@${remoteServer} 'df '${remoteDir})
		unset SSHPASS
		outputArray=($OUTPUT)
		remoteSpace=${outputArray[10]}
		echo storage space available = $remoteSpace
		
		if (( "$remoteSpace" <= "$localSpace" ))
		then
			formatScreen "1" "3"
			echo -----------------------------------------------------------
			echo Sorry there does not seem to be enough space on the remote server
			echo please make room or change the destination, this script will teinate.
			sleep 5
			exit
		fi
		
		echo there is enough space to store the files on the remote server
		sleep 3
		
		formatScreen "1" "3"
		echo "Copy compressed files to backup SCP server"
		echo -----------------------------------------------------------
		export SSHPASS=$userPassword1
		sshpass -e scp -o "StrictHostKeyChecking no" ${localDir}/sesBackup/* ${backupUser}@${remoteServer}:${remoteDir}/sesBackup
		unset SSHPASS
		sleep 3
		
		formatScreen "1" "3"
		echo -----------------------------------------------------------
		echo "Next steps:"
		echo "1) Shut down and rebuild the VM with ${veajor} ISO"
		echo "2) Install take ${verTake}"
		echo "3) Reapply DNS, NTP, TACACS, etc. from previous CLISH backup"
		echo "4) Run serestore.sh script"
		echo
		echo
		echo
		break

}

function restore(){
	formatScreen "1" "3"
	echo Please enter the backup userid
	echo -----------------------------------------------------------
	read -p 'Backup user name: ' backupUser
	
	getPassword
	
	formatScreen "1" "3"
	echo Please enter the Backup SCP server IP address
	echo -----------------------------------------------------------
	read -p 'Backup SCP server IP: ' remoteServer
	
	formatScreen "1" "3"
	echo Please enter the local backup base directory
	echo -----------------------------------------------------------
	read -p 'Local backup directory: ' localDirRaw
	localDir=$(echo "$localDirRaw" | sed 's:/*$::')
			
	formatScreen "1" "3"
	echo Please enter the remote backup base directory
	echo -----------------------------------------------------------
	read -p 'Remote backup directory: ' remoteDirRaw
	remoteDir=$(echo "$remoteDirRaw" | sed 's:/*$::')

	summary

	formatScreen "1" "3"
	echo "Creating local backup directories"
	echo -----------------------------------------------------------
	mkdir -p ${localDir}/sesBackup
	mkdir -p ${localDir}/sesOutput
	cd ${localDir}/sesBackup
	sleep 3
	
	formatScreen "1" "3"
	echo "Stopping services please be patient this may take a minute or two"
	echo ---------------------------------------------------------------------
	cpstop > ${localDir}/sesOutput/cpstopOutput.txt
	sleep 3
	
	formatScreen "1" "3"
	echo "Removing current logs and indexes"
	echo -----------------------------------------------------------
	 rm -rf $RTDIR/log_indexes/*20*
	 rm -f $INDEXERDIR/data/FetchedFiles
	sleep 3
	
	formatScreen "1" "3"
	echo "Download compressed files from SCP Server"
	echo -----------------------------------------------------------
	export SSHPASS=$userPassword1
	sshpass -e scp -o "StrictHostKeyChecking no" ${backupUser}@${remoteServer}:${remoteDir}/sesBackup/* ${localDir}/sesBackup/
	unset SSHPASS
	sleep 3
	ß
	formatScreen "1" "3"
	echo "Extract logs and indexes"
	echo -----------------------------------------------------------
	gtar -zxvf ${localDir}/sesBackup/log_indexes.tgz --directory=/
	gtar -zxvf ${localDir}/sesBackup/fw_logs.tgz --directory=/
	cp ${localDir}/sesBackup/FetchedFiles $INDEXERDIR/data
	sleep 3
	
	formatScreen "1" "3"
	echo "Running migrate_server import"
	echo -----------------------------------------------------------
	cd $FWDIR/scripts
	./migrate_server import -v ${veajor} ${localDir}/sesBackup/ses_Export.tgz
		
	formatScreen "1" "3"
	echo "Waiting for services to start" 
	echo -----------------------------------------------------------
	until $(api status | grep -q "API readiness test SUCCESSFUL"); do
	sleep 1
	done
	
	formatScreen "1" "3"
	echo "Next steps:"
	echo -----------------------------------------------------------
	echo "1) Reset SIC in SmartConsole"
	echo "2) Install Database in SmartConsole"
	echo "3) Run cprestart on manager"
	echo "5) Clean up backup directory: ${backupDir}"
	exit
}

menu





