#!/bin/bash

if (( $# != 1 )); then
	echo "USAGE: $0 <directory containing result files>"
	exit 1;
fi

#-------------------------------------------------------
# Result file naming scheme:
#
# The timing results for non-optimized queries are
# stored in files named as:
#
# <query file>.ordering.<N>.no.opt.trial.<N>.time
#
# while the time results for optimized queries are
# stored in files named as:
#
# <query file>.ordering.<N>.test.run.<N>.opt.trial.<N>.time
#
# The test run number indicates how many training
# runs have occurred prior to running the test query. 
#------------------------------------------------------

R_FILE="plot.graphs.R"
RESULT_FILES_PATH=$1;

function add_line
{
	echo "$*" >> $R_FILE;
}

#-----------------------------------------------
# Generate an R script that creates the graphs
#-----------------------------------------------

# remove the previously generated file if it exists
rm $R_FILE 2> /dev/null

# required for the errbar() method
add_line "library(Hmisc)"
# required for the barplot2() method
add_line "library(gplots)"
# for rendering to SVG
add_line "library(RSVGTipsDevice)"
#add_line "library(RSvgDevice)"

# In some cases (timeouts or queries that die), we will only have one trial time
# and this makes the standard error for that set of trials undefined.  For our
# purposes, we just want standard error to be zero in this case.

add_line "# user defined functions"
add_line ""
add_line "safe.standard.error <- function(row.vector) { if (length(row.vector) > 1) { sd(t(row.vector)) / sqrt(length(row.vector)) } else { 0 } }"
add_line "safe.mean <- function(vector) { if (length(vector) > 0) { mean(vector) } else { 0 } }"
add_line "safe.nrow <- function(elem) { if (is.null(elem)) { 0 } else { nrow(elem) } }"
add_line "pad.right <- function(row.vector, pad.elem, padded.length) {"
add_line "  if (length(row.vector) < padded.length) {"
add_line "    row.vector <- c(row.vector, rep(padded.length - length(row.vector), pad.elem))"
add_line "  } else {"
add_line "    row.vector"
add_line "  }"
add_line "}"
add_line ""

test_query_prefixes=$(ls $RESULT_FILES_PATH/*.test.run.*.time | perl -ple 's/(.*)\.ordering.*/\1/g' | sort | uniq) 

echo -e "test_query_prefixes:\n${test_query_prefixes}\n"

for test_query_prefix in $test_query_prefixes; do

	#-------------------------------------------------------------
	# Put the mean times for each test query ordering 
	# into a matrix. (Each mean represents the query time
	# for one test run.)
	#
	# Likewise, put the standard error for each query time into
	# a matrix so that we can calculate the error bars.
	#-------------------------------------------------------------

	add_line "mean.matrix <- cbind()"
	add_line "stderr.matrix <- cbind()"
	# indicates the exit status of queries if not normal (e.g. TIMEOUT)
	add_line "annotation.matrix <- cbind()"

	ordering_prefixes=$(ls ${test_query_prefix}.ordering.*.time | perl -ple 's/(.*\.ordering\.[0-9]+).*/\1/g' | sort | uniq)

	echo -e "ordering_prefixes:\n${ordering_prefixes}\n"

	for ordering_prefix in $ordering_prefixes; do

		# vector of mean execution times for each test run
		add_line "means <- c()";
		# vector of standard errors for each test run 
		add_line "stderrs <- c()";
		# vector of labels for each bar in a group
		add_line "bar.labels <- c()";
		# indicate exit status of query if not normal (e.g. TIMEOUT)
		add_line "bar.annotations <- c()";

		#--------------------------------------------------------------
		# Compute mean and standard error of non-optimized trials
		#--------------------------------------------------------------

		no_opt_vector=$(basename ${ordering_prefix})".no.opt"
		add_line "$no_opt_vector <- c()" 

		no_opt_trials=$(ls ${ordering_prefix}.no.opt.*.time | sort | uniq)

		echo -e "no_opt_trials:\n${no_opt_trials}\n"

		annotation=""

		for no_opt_trial in $no_opt_trials; do

			add_line "$no_opt_vector <- rbind($no_opt_vector, read.table('$no_opt_trial', header=FALSE) / 60)"

			status_file=$(echo ${no_opt_trial} | perl -ple 's/\.time$/.exit.status/')
			exit_status=$(cat ${status_file})
			if [ "${exit_status}" != "SUCCESS" ]; then
				annotation="${exit_status}"
			fi	

		done

		add_line "means <- cbind(means, safe.mean($no_opt_vector))"
		add_line "stderrs <- cbind(stderrs, safe.standard.error(t($no_opt_vector)))"
		add_line "bar.labels <- rbind(bar.labels, 'BASIC')"
		add_line "bar.annotations <- rbind(bar.annotations, '$annotation')"

		#-------------------------------------------------------------
		# Compute mean and standard error of optimized test runs
		#-------------------------------------------------------------

		test_run_prefixes=$(ls ${ordering_prefix}.test.run*.time | perl -ple 's/(.*)\.trial.*/\1/g' | sort | uniq)

		echo -e "test_run_prefixes:\n${test_run_prefixes}\n"

		test_run_count=0

		for test_run_prefix in $test_run_prefixes; do

			opt_vector=$(basename ${test_run_prefix})
			add_line "$opt_vector <- c()"

			trials=$(ls ${test_run_prefix}*.time | sort | uniq)

			annotation=""

			for trial in $trials; do

				add_line "$opt_vector <- rbind($opt_vector, read.table('$trial', header=FALSE) / 60)"
				
				status_file=$(echo $trial | perl -ple 's/\.time$/.exit.status/')
				exit_status=$(cat ${status_file})
				if [ "${exit_status}" != "SUCCESS" ]; then
					annotation="${exit_status}"
				fi	

			done

			add_line "means <- cbind(means, safe.mean($opt_vector))"
			add_line "stderrs <- cbind(stderrs, safe.standard.error(t($opt_vector)))"
			add_line "bar.labels <- rbind(bar.labels, 'GREEDY, ${test_run_count} training runs')"
			add_line "bar.annotations <- rbind(bar.annotations, '$annotation')"

			test_run_count=$((${test_run_count} + 1))

		done # for each test run

		#------------------------------------------------------------
		# Add mean times to matrix for test run, likewise for
		# standard errors.
		#------------------------------------------------------------

		add_line "mean.matrix <- cbind(mean.matrix, pad.right(t(means), 0, safe.nrow(mean.matrix)))"
		add_line "stderr.matrix <- cbind(stderr.matrix, pad.right(t(stderrs), 0, safe.nrow(stderr.matrix)))"
		add_line "annotation.matrix <- cbind(annotation.matrix, pad.right(t(bar.annotations), 0, safe.nrow(annotation.matrix)))"

	done # for each query ordering

	test_query=$(basename ${test_query_prefix})
	query_number=$(echo ${test_query_prefix} | perl -ple 's/.*query(.*)\.sparql/\1/g')
#	graph_file="${test_query}.png";
	graph_file="${test_query}.svg";

#	add_line "png('${graph_file}')"
	add_line "devSVGTips('${graph_file}', toolTipMode=0)"
#	add_line "devSVG(file='${graph_file}')"
	add_line ""
	add_line "# don't use scientific notation unless numbers have more than 10 digits"
	add_line "# (did this to prevent R from using scientific notation for y axis labels)"
	add_line "options(scipen=10)"
	add_line
	add_line "# generate color gradient for bars"
	add_line "shades.of.gray <- c()"
	add_line "inc <- (0.9 - 0.5) / nrow(mean.matrix)"
	add_line "for(i in 1:nrow(mean.matrix)) {"
	add_line "  intensity <- 0.5 + (i - 1)*inc"
	add_line "  shades.of.gray <- rbind(shades.of.gray, rgb(intensity, intensity, intensity))"   
	add_line "}"
	add_line ""
	add_line "# generate labels for bar groups"
	add_line "group.labels <- c()"
	add_line "for(i in 1:ncol(mean.matrix)) {"
	add_line "  group.labels <- rbind(group.labels, i - 1)" # paste('Test Ordering ', i - 1))"
	add_line "}"
	add_line
	add_line "# las = 3 means draw all axis labels vertically"
#	add_line "par(las=3)"
	add_line "# mar(bottom, left, top, right) sets margins (measured in lines of text)"
#	add_line "par(mar=c(10, 5, 4, 2))"
	add_line "par(mar=c(6, 5, 4, 2))"
	add_line "par(lab=c(10,10,7))"
	add_line
	add_line "xvals.matrix <- barplot2(mean.matrix, main='Execution Times for Query ${query_number}', legend.text=bar.labels, log='y', ylim=c(0.1,10000), ylab='Query Time (minutes)', xlab='Random Query Ordering', xjust=0, names.arg=group.labels, col=shades.of.gray, beside=TRUE)"	
#   add_line "xvals.matrix <- barplot2(mean.matrix, main='Execution Times for Query ${query_number}', legend.text=bar.labels, ylab='Query Time (seconds)', xlab='Random Query Ordering', xjust=0, names.arg=group.labels, col=shades.of.gray, beside=TRUE)"	
	add_line "xvals <- xvals.matrix[ 1:length(xvals.matrix) ]"
	add_line "yvals <- mean.matrix[ 1:length(mean.matrix) ]"
	add_line "ydeltas <- stderr.matrix[ 1:length(stderr.matrix) ]"
#	add_line "errbar(xvals, yvals, yvals + ydeltas, yvals - ydeltas, xlab='Random Input Query Ordering', ylab='Query Time (minutes)', cex=0.5, add=TRUE)"
	add_line "errbar(xvals, yvals, yvals + ydeltas, yvals - ydeltas, cex=0.5, add=TRUE)"
	add_line 
	add_line "# TIMEOUT line"
	add_line "timeout = 60"
	add_line "abline(h=timeout, lty=2)"
	add_line "# par('cra') gets the character width/height in pixels"
	# 25 is an abitrary offset to get the label above the line. 
	# I got frustrated trying to figure out how to offset the label properly.
	add_line "text(0, timeout + 25, paste('TIMEOUT = ', timeout, ' minutes'), pos=4)" 
	add_line
	add_line "# apply text annotations indicating query exit status (e.g. TIMEOUT)"
	add_line "#annotation.vector <- annotation.matrix[ 1:length(annotation.matrix) ]"
	add_line "#text(xvals, rep(0, length(xvals)), annotation.vector, srt=90, adj=0)"
	add_line ""
	add_line "dev.off()"

done # for each test query

R --vanilla < plot.graphs.R > plot.graphs.R.out 2>&1

if [ $? -ne 0 ]; then 
	echo -e "error occurred during execution of R:\n" 
	tail -n 20 plot.graphs.R.out
fi
