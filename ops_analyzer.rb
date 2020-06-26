#!/usr/bin/env ruby
# This script is designed to parse the output of dump_historic_ops and then
# measure the time spent between different phases. Often when analysing this
# output, firstly it can be difficult to parse visually because there is so
# much data and secondly the data only consists of absolute times so it is not
# easy to know the time spent in various phases.
#
# It's also designed to help isolate operations that were slow locally (to the
# op_commit phase) as opposed to operations that were slow remotely (waiting
# for subops) and the fact that the apply phase causes the entire operation to
# wait around unti lthe filestore_max_sync_interval (5 seconds by default)
# which means that the built-in age/duration timers are mostly unhelpful.
#
# Anyone using this script will likely want to customise the hash
# 'measure_between' in order to measure the time between interesting events.
#
# Hopefully in future the script will be expanded to parse and report on the
# data, but for now it just naively outputs the operations and the timing in
# order of longest to shortest. At the time of writing I mostly would parse
# a bunch of output, then grep the various timing pairs looking for interesting
# times.
#
# You'll also likely want to increase osd_op_history_size from the default 20
# to something larger at least 200 or maybe much larger depending on how many
# operations/second your cluster is processing and how many slow operations you
# are getting. Mind your memory usage!

# Author: Trent Lloyd
# https://github.com/lathiat/ceph-tools
# License: GPL v3

# Modified by Stephen Blinick 
measure_between = {"reached_pg" => ["started"],
                   "initiated" => ["queued_for_pg"],
                   "queued_for_pg" => ["reached_pg"],
                   "journal_completion_queued" => ["sub_op_comitted"],
                   "sub_op_comitted" => ["sub_op_applied"],
                   "sub_op_applied" => ["commit_sent"],
                   "commit_sent" => ["done"],
}

# ORIGINAL
#measure_between = {"reached_pg" => ["journaled_completion_queued"],
#                   "initiated" => ["commit_sent", "journaled_completion_queued", "reached_pg", "op_commit"],
#                   "started" => ["commit_queued_for_journal_write"],
#                   "commit_queued_for_journal_write" => ["journaled_completion_queued", "op_commit"],
#}

require 'pp'
require 'json'
require 'date'

#j = JSON.parse('{"network_nothingburgers": "delicious"}')
j = Array.new
ARGV.each { |fname|
   pp fname
   input_file = open(fname)
   nf = JSON.parse(input_file.read)
   #j.merge!(nf)
   if nf["ops"]
     j.concat(nf["ops"])
   else
     j.concat(nf["Ops"])
   end
}
#input_fn = ARGV[0]
#input_file = open(input_fn)
#j = JSON.parse(input_file.read)
#pp j
ops = {}

#if j["ops"]
#    op_in = j["ops"]
#else
#    op_in = j["Ops"]
#end

interesting = []

mega_ops = []

#op_in.each do |op|
j.each do |op|
    key = op["description"]
    # HACK just skip dup op descriptions, only seems to be weird things like scrub NOT SUBOPS
    #raise if ops[key]
    next if ops[key]
    ops[key] = {}
    ops[key][:op] = op
    infostuff = op["type_data"]
    state, client, steps = infostuff[""]
    state = "sucks"
    steps = infostuff["events"]
    client = infostuff["client_info"]

    times = {}
    initiated_t = DateTime.parse(op["initiated_at"]).to_time
    next if steps.nil?

    measures = {}
    last_step = {"time" => op["initiated_at"], "event" => "start"}
    last_step_t = DateTime.parse(op["initiated_at"]).to_time
    step_to_time = {}
    steps.each do |step|
        step_t = DateTime.parse(step["time"]).to_time
        step_to_time[step["event"]] = DateTime.parse(step["time"]).to_time
        delta_t = step_t - last_step_t
        key = "#{last_step["event"]}-#{step["event"]}"
        times[key] = delta_t unless times[key]
        last_step = step
        last_step_t = step_t
    end

    measure_between.each do |start_event_name, end_event_names|
        start_event = step_to_time[start_event_name]
        end_event_names.each do |end_event_name|
            end_event = step_to_time[end_event_name]
            if start_event and end_event
                times["#{start_event_name}-#{end_event_name}"] = end_event - start_event
            end
        end
    end

    # We are looking for local operations.. if it takes >0.1s to get to
    # reached_pg then the issue is likely rw locks. If it takes less than 0.5
    # seconds to get to op_commit then it is a 'relatively' fast operation
    # (still slower than desired)
    #next if times["initiated-reached_pg"] > 0.5
    if times["initiated-op_commit"]
      next if times["initiated-op_commit"] < 0.3
    end
    next if times["waiting for rw locks-reached_pg"]


    #pp op
    ttltime = op["duration"]
    agetime = op["age"]
    desc = op["description"]

    #print "== OP == %s, age %s took %s\n" % [desc, agetime, ttltime]
    sorttimes = times.to_a.sort{|b, a| a[1] <=> b[1] }
    opout = [ agetime, desc, ttltime, sorttimes.take(3) ]
    mega_ops.append(opout)

    sorttimes.take(3).each do |obj|
      ptc = obj[1].to_f / ttltime.to_f * 100.0
      #print "  > %s (%3.2f) = %3.0f %%\n" % [obj[0], obj[1].to_f, ptc]
    end
end

printtop=20
print "------------------------------\n"
print "----- Top %d longest ops \n" % [printtop]
print "------------------------------\n"
mega_ops.to_a.sort{|b, a| a[2] <=> b[2] }.take(printtop).each do |opout|
    ttltime = opout[2]
    agetime = opout[0]
    desc = opout[1]
    print "== OP == %s, age %s took %s\n" % [desc, agetime, ttltime]
    opout[3].each do |obj|
      ptc = obj[1].to_f / ttltime.to_f * 100.0
      print "  > %s (%3.2f) = %3.0f %%\n" % [obj[0], obj[1].to_f, ptc]
    end
end

# ======== one more time but summarize everything

totalops = 0
megatimes = Hash.new
megapct = Hash.new

mega_ops.to_a.sort{|b, a| a[2] <=> b[2] }.each do |opout|
    totalops = totalops+1
    ttltime = opout[2]
    agetime = opout[0]
    desc = opout[1]
    opout[3].each do |obj|
      ptc = obj[1].to_f / ttltime.to_f * 100.0
      if megatimes.include? obj[0]
         megatimes[obj[0]] += obj[1].to_f
         megapct[obj[0]] += ptc
      else
         megatimes[obj[0]] = obj[1].to_f
         megapct[obj[0]] = ptc
      end
    end
end
print "------------------------------\n"
print "----- Summary of all ops \n" % [printtop]
print "------------------------------\n"
print "Total # Ops analyzed: %d \n" % [totalops]
print "* Across all ops, spots that took most total time:\n"
megatimes.to_a.sort{|b, a| a[1] <=> b[1] }.each do |megatime|
  print "    >> %s -- Total %3.2f seconds\n" % [megatime[0], megatime[1]]
end
print "* Across all ops, average % of time each spot took in the op:\n"
megapct.to_a.sort{|b, a| a[1] <=> b[1] }.each do |megap|
  print "    >> %s -- Avg %3.2f%% \n" % [megap[0], megap[1]/totalops]
end
