require 'rubygems'
require 'midilib'
require 'generator'

# midibeep.rb: Convert a Standard MIDI (.mid) file into Spectrum BEEP statements
# Copyright (C) 2009 Matthew Westcott
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
# 
# Contact details: <matthew@west.co.tt>
# Matthew Westcott, 14 Daisy Hill Drive, Adlington, Chorley, Lancs PR6 9NE UNITED KINGDOM

MIN_NOTE_LENGTH = 20_000 # Minimum number of microseconds each note must be played for
#MIN_NOTE_LENGTH = 10_000 # Works better with Rachmaninov. :-)
LINE_NUMBER_INCREMENT = 5

# Create a new, empty sequence.
seq = MIDI::Sequence.new()

# Utility class to merge several Enumerables (each of which emit comparable
# objects in order) into one ordered Enumerable. Used to merge all MIDI tracks
# into a single stream
class IteratorMerger
	include Enumerable
	
	def initialize
		@streams = []
	end
	
	def add(enumerable)
		# convert enumerable object to an iterator responding to end?, current and next
		@streams << Generator.new(enumerable)
	end
	
	def each
		until @streams.all?{|stream| stream.end?}
			# while there are still some objects in the stream,
			# pick the stream whose next object is first in order
			next_stream = @streams.reject{|stream| stream.end?}.min{|a,b|
				a.current <=> b.current
			}
			yield next_stream.next
		end
	end
end

# Fiddle the ordering of MIDI event objects so that lower notes come first,
# which means that when we come to play them they'll fan upwards
class MIDI::Event
	def <=>(other)
		this_event_comparator = [
			self.time_from_start, (self.is_a?(MIDI::NoteEvent) ? self.note : -1)]
		other_event_comparator = [
			other.time_from_start, (other.is_a?(MIDI::NoteEvent) ? other.note : -1)]
		this_event_comparator <=> other_event_comparator
	end
end

File.open(ARGV[0], 'rb') { | file |
	# Create a stream of all MIDI events from all tracks
	event_stream = IteratorMerger.new
	seq.read(file) { | track, num_tracks, i |
		# puts "Loaded track #{i} of #{num_tracks}"
		next unless track
		event_stream.add(track)
	}
	
	# Keeping track of the time at which the last tempo change event occurred,
	# and the new tempo, will allow us to calculate an exact microsecond time
	# for each subsequent event.
	last_tempo_event_microsecond_time = 0
	default_bpm = MIDI::Sequence::DEFAULT_TEMPO
	default_microseconds_per_beat = MIDI::Tempo.bpm_to_mpq(default_bpm)
	last_tempo_event = MIDI::Tempo.new(default_microseconds_per_beat)
	
	last_note_on_event = nil
	last_note_on_microsecond_time = 0
	last_note_off_event = nil
	last_note_off_microsecond_time = 0
	
	line_number = LINE_NUMBER_INCREMENT # tracks the BASIC line number to emit
	
	overshoot = 0 # number of microseconds we've played longer than we should have,
	# to allow excessively short notes to be heard
	
	# Function to emit a BEEP statement for a note whose start time and pitch
	# are given by last_note_on_event and last_note_on_microsecond_time, and
	# end time is passed as end_microsecond_time.
	# This is called on encountering the next 'note on' event (at which point
	# we know how long the previous note should last), and also on the final
	# 'note off' event of the stream.
	add_beep = lambda { |end_microsecond_time|
		real_note_duration = end_microsecond_time - last_note_on_microsecond_time
		# Reduce by overshoot if necessary, to compensate for previous notes
		# that were played for longer than the real duration (due to MIN_NOTE_LENGTH)
		# 
		# Playing a note of duration target_duration will get us back to the correct time
		# (aside from the fact that this might be negative...)
		target_duration = real_note_duration - overshoot
		
		# Extend actual duration to at least MIN_NOTE_LENGTH
		actual_duration = [target_duration, MIN_NOTE_LENGTH].max
		overshoot = actual_duration - target_duration
		# translate MIDI note number to BEEP pitch: middle C is 48 in MIDI, 0 in BEEP
		pitch = last_note_on_event.note - 48
		puts "#{line_number} BEEP #{actual_duration / 1_000_000.0},#{pitch}"
		line_number += LINE_NUMBER_INCREMENT
	}
	
	event_stream.each do |event|
		# Calculate absolute microsecond time of the event
		delta_from_last_tempo_event = event.time_from_start - last_tempo_event.time_from_start
		current_microseconds_per_beat = last_tempo_event.tempo
		
		#beats_since_last_tempo_event = delta_from_last_tempo_event / seq.ppqn
		#microseconds_since_last_tempo_event = beats_since_last_tempo_event * current_microseconds_per_beat
		# -> refactored to avoid floating point division:
		microseconds_since_last_tempo_event = delta_from_last_tempo_event * current_microseconds_per_beat / seq.ppqn
		
		current_microsecond_time = last_tempo_event_microsecond_time + microseconds_since_last_tempo_event
		
		case event
			when MIDI::Tempo
				# Keep track of tempo changes so that we can calculate subsequent microsecond timings
				last_tempo_event = event
				last_tempo_event_microsecond_time = current_microsecond_time
			when MIDI::NoteOnEvent
				if last_note_on_event
					# insert a BEEP for the previous note, now we know how long it should be
					add_beep.call(current_microsecond_time)
				end
				last_note_on_event = event
				last_note_on_microsecond_time = current_microsecond_time
			when MIDI::NoteOffEvent
				# keep track of the last note off event, so that we can time the last note
				# of the track by it
				last_note_off_event = event
				last_note_off_microsecond_time = current_microsecond_time
		end
		
	end
	
	# add a beep for the final note
	if (last_note_on_event and last_note_off_event)
		add_beep.call(last_note_off_microsecond_time)
	end
}
