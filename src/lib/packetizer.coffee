util = require("util")
EventEmitter = require("events").EventEmitter

#
#  convert the given array/buffer of bytes to its ASCII representation
#
#  args
#    array
#      an array-like object of bytes to be interpreted as text
#
decode = (array) ->
  decoded = ""
  i = 0
  while i < array.length
    if array[i] is 10 or array[i] is 13
      decoded += "\n" # not technically true
    else
      decoded += String.fromCharCode(array[i])
    i++
  decoded

#
#  check to see if we're done with this packet
#
#  args
#    message
#      the message so far
#    incoming
#      latest byte/character
#    ender
#      the packet termination sequence
#
#  return
#    true/false if the packet should end
#
checkEnd = (message, incoming, ender) ->
  # the slow way:
  # return (message + incoming).indexOf(ender) != -1;
  # the fast way:
  (message + incoming).slice(message.length - ender.length + 1) is ender

class Packetizer
  #
  #  packetize the incoming UART stream
  #
  #  args
  #    uart
  #      the uart port being packetized
  #    ender
  #      charaters at the end of each packet. typically \r\n or similar.
  #    blacklist
  #      an array of messages you don't care about, ie ['UNDER-VOLTAGE WARNNING']
  #
  constructor: (uart, ender, blacklist, debug) ->
    @debug = debug or false
    @ender = ender or "\n"
    @blacklist = blacklist or ["UNDER-VOLTAGE WARNNING"]
    #  get yourself some messages
    @messages = []
    @packetNumber = 0
    @maxBufferSize = 10
    @previousCharacter = ""
    @latestMessage = ""
    # Initialize UART
    @uart = uart
    return
  util.inherits Packetizer, EventEmitter
  getPacketCount: ->
    @packetNumber
  #
  #  get/set the buffer size
  #
  #  args
  #    len
  #      the desired max buffer size. leave empty to get the current size
  #
  #  returns
  #    the size of the buffer after changes, if any
  #
  bufferSize: (len) ->
    @maxBufferSize = len  if arguments.length > 0
    @maxBufferSize
  #
  #  get the most recent num packets
  #
  #  args
  #    num
  #      how many packets? coerced to be <= the buffer size
  #
  #  returns
  #    packets
  #      an array of the last num packets
  #
  getLatestPackets: (num) ->
    packets = []
    i = 0
    packets = while i < Math.min(num, @maxBufferSize, @messages.length)
      @messages[i++]
    # while i < Math.min(num, @maxBufferSize, @messages.length)
    #   packets.push @messages[i]
    #   i++
    packets
  #
  #  checks to see if the given text is blacklisted
  #
  #  args
  #    data
  #      string to test
  #
  #  return value
  #    true if blacklisted, false otherwise
  #
  checkBlacklist: (data) ->
    # console.log('--> checking', data, 'against blacklist...')
    # return this.blacklist.some(function(item) {
    #   return item == data;
    # });
    data in @blacklist
  packetize: ->
    self = this
    @uart.on "data", (bytes) ->
      i = 0
      while i < bytes.length
        thing = decode([bytes[i]])
        if checkEnd(self.latestMessage, thing, self.ender)
          if not /^\s*$/.test(self.latestMessage + thing) and not self.checkBlacklist(self.latestMessage)
            console.log "Got a packet", self.latestMessage  if self.debug
            #  we don't want "empty" or blacklisted packets
            self.emit "packet", self.latestMessage
            # console.log('--> emitting',  self.latestMessage);
            self.messages.push self.latestMessage
            self.packetNumber++
            self.emit "overflow", self.messages.shift()  if self.packetNumber > self.maxBufferSize
          #  sometimes we may want to know
          self.emit "blacklist", self.latestMessage  if self.checkBlacklist(self.latestMessage)
          self.latestMessage = ""
          self.previousCharacter = ""
        else
          self.latestMessage += thing
          self.previousCharacter = thing
        i++
      return
    return

module.exports = Packetizer