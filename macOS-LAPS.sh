#!/bin/bash

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#
# Copyright (c) 2020 Jamf.  All rights reserved.
#
#       Redistribution and use in source and binary forms, with or without
#       modification, are permitted provided that the following conditions are met:
#               * Redistributions of source code must retain the above copyright
#                 notice, this list of conditions and the following disclaimer.
#               * Redistributions in binary form must reproduce the above copyright
#                 notice, this list of conditions and the following disclaimer in the
#                 documentation and/or other materials provided with the distribution.
#               * Neither the name of the Jamf nor the names of its contributors may be
#                 used to endorse or promote products derived from this software without
#                 specific prior written permission.
#
#       THIS SOFTWARE IS PROVIDED BY JAMF SOFTWARE, LLC "AS IS" AND ANY
#       EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
#       WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
#       DISCLAIMED. IN NO EVENT SHALL JAMF SOFTWARE, LLC BE LIABLE FOR ANY
#       DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
#       (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
#       LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
#       ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
#       (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
#       SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#
# This script was created to be able to regularly refresh the local FileVault enabled admin
# account password and save the new password to Jamf Pro via an Extension Attribute. This 
# workflow is commonly referred to as LAPS (Local Administrator Password Solution).
#
# REQUIREMENTS:
#           - Jamf Pro
#           - macOS Clients running version 10.15 or later
#
#
# For more information, visit https://github.com/kc9wwh/macOSLAPS
#
# Written by: Joshua Roskos | Jamf
# Created on: Friday, May 8th 2020
# Forked and updated by: Ryan Stasel | University of Oregon
#
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#
# CHANGE LOG
# 		2020-05-08: First Release of macOSLAPS
#		2020-10-19: Fork. Add minimum password requirement
#		2020-10-20: Adding LAPS datetime
#
#
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

## User Variables
jamfProURL="$4"
jamfProUser="$5"
LAPSaccount="$7"
extensionAttributeID="$8"
length=${11}
LAPSdateEA=115

## System Variables
mySerial=$( system_profiler SPHardwareDataType | grep Serial |  awk '{print $NF}' )
jamfProPass=$( echo "${6}" | /usr/bin/openssl enc -aes256 -d -a -A -S "${9}" -k "${10}" )
jamfProID=$( curl -H "Accept: text/xml" -skfu "${jamfProUser}:${jamfProPass}" "${jamfProURL}/JSSResource/computers/serialnumber/${mySerial}/subset/general" | awk -F'<id>|</id>' '{print $2}' )


## Grab Current LAPS Password
LAPScurrent=$( curl -sk -u "${jamfProUser}:${jamfProPass}" ${jamfProURL}/JSSResource/computers/id/"${jamfProID}"/subset/extension_attributes | xmllint --format - | grep -A4 "<id>${extensionAttributeID}</id>" | grep "<value>.*</value>" | awk -F "<value>|</value>" '{print $2}' )

## Generate New LAPS Password of length $length and make sure it meets certain requirements (min 1 UPPER, lower, and digit)
while [ -z $LAPSnew ]; do
	LAPSnew=$(openssl rand -base64 100 | tr -dc A-Za-z0-9 | tr -d 0OlI1 | cut -c -$length | egrep "[ABCDEFGHIJKLMNOPQRSTUVWXYZ]"| egrep "[abcdefghijklmnopqrstuvwxyz"] | egrep "[0-9]")
done

## Echo Password to Policy Logs
echo "LAPS Current Pass: ${LAPScurrent}"
echo "LAPS New Pass: ${LAPSnew}"

## Change & Verify Local LAPS Password
sysadminctl -adminUser ${LAPSaccount} -adminPassword ${LAPScurrent} -resetPasswordFor ${LAPSaccount} -oldPassword ${LAPScurrent} -newPassword ${LAPSnew} &>/dev/null

diskutil apfs updatePreboot / &>/dev/null

/usr/bin/dscl /Search -authonly "${LAPSaccount}" "${LAPSnew}" &>/dev/null
if [[ "$?" == "0" ]]; then
	echo "LAPS Password Updated Successfully!"
else
	echo "ERROR: LAPS Password Not Updated"
	exit 1
fi

## Upload & Verify New LAPS Password to API
curl -sk -u "${jamfProUser}:${jamfProPass}" ${jamfProURL}/JSSResource/computers/id/"${jamfProID}" -H "Content-Type: text/xml" -X PUT -d "<computer><extension_attributes><extension_attribute><id>${extensionAttributeID}</id><value>${LAPSnew}</value></extension_attribute></extension_attributes></computer>"

LAPSverify=$( curl -sk -u "${jamfProUser}:${jamfProPass}" ${jamfProURL}/JSSResource/computers/id/"${jamfProID}"/subset/extension_attributes | xmllint --format - | grep -A4 "<id>${extensionAttributeID}</id>" | grep "<value>.*</value>" | awk -F "<value>|</value>" '{print $2}' )
if [[ "${LAPSnew}" == "${LAPSverify}" ]]; then
	## Update LAPS date
	curDate=$(date '+%Y-%m-%d %H:%M:%S')
	curl -sk -u "${jamfProUser}:${jamfProPass}" ${jamfProURL}/JSSResource/computers/id/"${jamfProID}" -H "Content-Type: text/xml" -X PUT -d "<computer><extension_attributes><extension_attribute><id>${LAPSdateEA}</id><value>${curDate}</value></extension_attribute></extension_attributes></computer>"
	echo "API Update Successful"
else
	echo "ERROR: Unable to update API...Reverting Password"
	sysadminctl -adminUser ${LAPSaccount} -adminPassword ${LAPSnew} -resetPasswordFor ${LAPSaccount} -oldPassword ${LAPSnew} -newPassword ${LAPScurrent} &>/dev/null
	if [[ "$?" == "0" ]]; then
		echo "Local Password Successfully Reverted"
	else
		echo "ERROR: Unable to revert local password"
		exit 3
	fi
	exit 2
fi

exit 0
