#
# Packetizer is great in that it builds packets, but sometimes replies don't
# come in in an orderly fashion. If this happens, we need to be able to be able
# to route them appropriately.
#

util = require("util")
EventEmitter = require("events").EventEmitter

###*
Iterate each value of array and check if value contains
a specific string.

Differs from indexOf in that it performs indexOf on each
value in the string, so only a partial match is needed.

@param string, the string to search for
@returns true if match, else false
@note will return true at first occurrence of match
@note will check value.indexOf(string) AND string.indexOf(value)
@example:

['Apple', 'Pear'].indexOf('Pear') === 1
['Apple', 'Pear'].indexOf('Pe') === -1
['Apple', 'Pear'].indexOf('Pearing') === -1

['Apple', 'Pear'].softContains('Pear') === true
['Apple', 'Pear'].softContains('Pe') === false
['Apple', 'Pear'].softContains('Pearing') === true
###
Array::softContains = (searchStr) ->
  i = 0

  while i < @length
    return false  if typeof this[i] isnt "string"
    return true  if searchStr.indexOf(this[i]) isnt -1
    i++
  false


class Postmaster
  #
  #  Constructor for the postmaster
  #
  #  args
  #    myPacketizer
  #      A packetizer to listen to
  #    enders
  #      An Array of Strings that constitute the end of a post
  #    overflow
  #      A callback function to call when the message buffer overflows. Callback args are err and data
  #    size
  #      Size (in packets) of the buffer
  #    debug
  #      Are we in debug mode?
  #  
  constructor:  (myPacketizer, enders, overflow, size, debug) ->
    @packetizer = myPacketizer
    @uart = myPacketizer.uart
    @RXQueue = []
    @callback = null
    @message = ""
    @started = false
    @alternate = null
    @enders = enders or [
      "OK"
      "ERROR"
    ]
    @debug = debug or false
    overflow = overflow or (err, arg) ->
      if err
        console.log "err: ", err
      else
        console.log "overflow!\n", arg
      return

    size = size or 15
    self = this
    
    #  When we get a packet, see if it starts or ends a message
    @packetizer.on "packet", (data) ->
      
      #
      #    Wraps message as default start, which means a reply packet
      #    must start with the message to be valid. ex: ['AT']
      #    
      
      #
      #    If true, the values of `start` only need to exist within
      #    the incoming data, instead of at the beginning of the packet.
      #    Good for posts with known headers but unknown bodies.
      #    
      
      # If true, we are using alternate starts and enders
      
      # Array of valid start strings, ex: ['AT', 'OK', 'LETS BEGIN']
      
      # Use the alternate starts, enders
      
      # Use soft checking of start array
      hasCallback = ->
        self.callback isnt null
      hasStarted = ->
        self.started
      isDataInStartArrayStrict = ->
        (if starts.indexOf(data) is -1 then false else true)
      
      #
      #    Sometimes a packet contains other characters in addition to
      #    the string we want, for example:
      #      ['OK', 'ERROR'].indexOf('OK.')
      #    in this case indexOf will not be truthy, while
      #      ['OK', 'ERROR'].softContains('OK.')
      #    will be truthy.
      #
      #    These type of responses from the SIM900 chip are common when querying
      #    statuses. For example
      #      AT+CGATT?
      #    will return differently based on status, for example both
      #      +CGATT: 0
      #      +CGATT: 1
      #    are valid responses. By using softContains we can assure that both
      #    are valid enders.
      #    
      isDataInStartArraySoft = ->
        starts.softContains data
      
      #
      #    If we aren't busy, or
      #    if we are busy but the first part of the reply doesn't match the message, or
      #    if we are busy and we are using alternates...
      #    it's unsolicited
      #    
      isUnsolicited = ->
        unless hasCallback()
          self._debugPrint "---->>>>>>> Condition 1"
          return true
        if not hasStarted() and not useSoftContains and not isDataInStartArrayStrict()
          self._debugPrint "---->>>>>>> Condition 2"
          return true
        if not hasStarted() and useSoftContains and not isDataInStartArraySoft()
          self._debugPrint "---->>>>>>> Condition 3"
          return true
        false

      starts = [self.message]
      enders = self.enders
      useSoftContains = undefined
      useAlternate = undefined

      if self.alternate
        starts = self.alternate[0]
        enders = self.alternate[1]
        useAlternate = true
        useSoftContains = (if self.alternate[2] then true else false)
      else
        useAlternate = false
        useSoftContains = false

      self._debugPrint "postmaster got packet: " + [data], "\nstarts:", starts, "\nenders:", enders
      self._debugPrint "---------------"
      self._debugPrint "hasCallback", hasCallback()
      self._debugPrint "hasStarted", hasStarted()
      self._debugPrint "useSoftContains", useSoftContains
      self._debugPrint "isDataInStartArrayStrict", isDataInStartArrayStrict()
      self._debugPrint "isDataInStartArraySoft", isDataInStartArraySoft()
      self._debugPrint "isUnsolicited", isUnsolicited()
      self._debugPrint "---------------"
      if isUnsolicited()
        self._debugPrint "->>>>>>>>>> unsolicited"
        self._debugPrint data
        self.emit "unsolicited", data
      else
        self._debugPrint "adding", [data], "to the RXQueue"
        self.started = true
        self.RXQueue.push data
        
        #  Check to see of we've finished the post
        if enders.indexOf(data) > -1
          self._debugPrint "\t---> Found " + data + " in enders:\n", enders, "\nEmitting a post with:\n", self.RXQueue
          temp = self.RXQueue
          self.RXQueue = []
          self.started = false
          self.alternate = null
          self.emit "post", null, temp
      
      #  Check overflow
      if self.RXQueue.length > size
        self.emit "overflow", null, self.RXQueue
        self.RXQueue = []
        self.started = false
        self.alternate = null
        self.message = ""
      return

    @on "overflow", overflow
    return

  util.inherits Postmaster, EventEmitter

  #
  #  Send a message and add call its callback with the data from the reply
  #
  #  args
  #    message
  #      What to send (String or Buffer)
  #    callback
  #      The callback function to call with the resulting data
  #    patience
  #      Miliseconds to wait before returning with an error
  #    alternate
  #      An Array of Arrays of alternate starts and ends of the reply post (Strings). Of the form [[s1, s2 ...], [e1, e2, ...]]. These values are used in place of traditional controls.
  #      If the third element of alternate is truth-y, then the given start values only need exist within the incoming data (good for posts with known headers but unknown bodies).
  #    debug
  #      Debug flag
  #
  #  Callback parameters
  #    err
  #      Error, if applicable
  #    data
  #      An array of Strings, usually starting with the original call, usually ending with one of 'OK', '>', or 'ERROR'
  #  
  send: (message, patience, callback, alternate, debug) ->
    self = this
    self.debug = debug or false

    if self.callback isnt null
      callback new Error("Postmaster busy"), []
    else
      self.alternate = alternate  if alternate
      
      #  Set things up
      self.callback = callback
      patience = patience or 10000
      self.message = message
      self.uart.write message
      self.uart.write "\r\n"
      self._debugPrint "sent", [message], "on uart", [self.uart]
      reply = (err, data) ->
        temp = self.callback
        self.callback = null
        temp err, data  if temp
        return


      #  If we time out
      panic = setTimeout(->
        self.removeListener "post", onPost
        err = new Error("no reply after " + patience + " ms to message \"" + message + "\"")
        err.type = "timeout"
        reply err, []
        self.forceClear()
        return
      , patience)
      
      #  If we get something
      onPost = (err, data) ->
        clearTimeout panic
        self.removeListener "post", onPost
        self._debugPrint "postmaster replying", data
        reply err, data
        return

      self.on "post", onPost
    return

  #  Reset the postmaster to its default state, emit what you have as unsolicited
  forceClear: (typ) ->
    type = typ or "unsolicited"
    @emit type, @RXQueue
    @RXQueue = []
    @callback = null
    @message = ""
    @started = false
    @alternate = null
    return

  _debugPrint: ->
    console.log util.format.apply(util, arguments)  if @debug
    return

module.exports = Postmaster