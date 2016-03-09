#!/bin/bash
# sleeper 0.0.1
# Generated by dx-app-wizard.
#
# Basic execution pattern: Your app will run on a single machine from
# beginning to end.
#
# Your job's input variables (if any) will be loaded as environment
# variables before this script runs.  Any array inputs will be loaded
# as bash arrays.
#
# Any code outside of main() (or any entry point you may add) is
# ALWAYS executed, followed by running the entry point itself.
#
# See https://wiki.dnanexus.com/Developer-Portal for tutorials on how
# to modify this file.

# Make sure to get GNU parallel here
sed -i 's/^# *\(deb .*backports.*\)$/\1/' /etc/apt/sources.list
apt-get update
apt-get install --yes parallel

RERUN=1

while test $RERUN -ne 0; do
	sudo pip install pytabix
	RERUN="$?"
done

main() {

    echo "Value of sleep_time: '$sleep_time'"

    # Fill in your application code here.
    #
    # To report any recognized errors in the correct format in
    # $HOME/job_error.json and exit this script, you can use the
    # dx-jobutil-report-error utility as follows:
    #
    #   dx-jobutil-report-error "My error message"
    #
    # Note however that this entire bash script is executed with -e
    # when running in the cloud, so any line which returns a nonzero
    # exit code will prematurely exit the script; if no error was
    # reported in the job_error.json file, then the failure reason
    # will be AppInternalError with a generic error message.

	sleep $sleep_time
	source ~/.dnanexus_config/unsetenv

}
