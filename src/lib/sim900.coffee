###

SIM900
https://github.com/semencov/rpi-sim900

Copyright (c) 2015 Yuri Sementsov
Licensed under the MIT license.

###

'use strict'

util = require("util")
EventEmitter = require("events").EventEmitter
Packetizer = require("./packetizer")
Postmaster = require("./postmaster")

DEBUG = false   #  Debug messages to the console

class SIM900
  #  Constructor
  #
  #  Args
  #    hardware
  #      The Tessel port to be used for priary communication
  #  
  constructor: (device, options={}) ->
    options.lineEnd = "\r\n"  unless options.lineEnd
    options.baudrate = 115200  unless options.baudrate

    @options = options
    @device = device

    @uart = new serialport.SerialPort(@device,
      baudrate: @options.baudrate
      parser: serialport.parsers.raw
      # parser: serialport.parsers.readline(@options.lineEnd)
    )

    @opened = false
    @emissions = []

    @isCalling = false
    @isRinging = false
    @isBusy = false

    @packetizer = new Packetizer(@uart)
    @packetizer.packetize()
    
    #  The defaults are fine for most of Postmaster's args
    @postmaster = new Postmaster(self.packetizer, ["OK","ERROR","> ","DOWNLOAD"], null, null, DEBUG)
    
    return

  util.inherits SIM900, EventEmitter

  _establishContact: (callback, rep, reps) ->
    self = this
    rep = rep or 0
    reps = reps or 5
    patience = 1000
    @_txrx "AT", patience, (checkIfWeContacted = (err, data) ->
      if err and err.type is "timeout" and rep < reps
        self.togglePower tryAgainAfterToggle = ->
          self._establishContact callback, rep + 1, reps
          return

      else unless err
        self.emit "ready", data
        callback err, self  if callback
      else
        err = new Error("Could not connect to SIM900 Module")
        setImmediate ->
          self.emit "error", err
          return

        callback err, self  if callback
      return
    ), [
      [
        "AT"
        "\\x00AT"
        "\u0000AT"
        "OK"
      ]
      ["OK"]
      1
    ]
    return

  _txrx: (message, patience, callback, alternate) ->
    message = message or "AT"
    patience = patience or 250
    callback = callback or ((err, arg) ->
      if err
        debug "err:\n", err
      else
        debug "reply:\n", arg
      return
    )
    alternate = alternate or null
    patience = Math.max(patience, 100)
    @postmaster.send message, patience, callback, alternate
    return

  answerCall: (callback) ->
    self = this
    @_txrx "ATA", 10000, (err, data) ->
      self.inACall = true  unless err
      callback err, data
      return

    return

  _chain: (messages, patiences, replies, callback) ->
    self = this
    if messages.length isnt patiences.length or messages.length isnt replies.length
      callback new Error("Array lengths must match"), false
    else
      _intermediate = (err, data) ->
        correct = not err
        if replies[0]
          i = 0

          while i < data.length
            correct = correct and ([
              data[i]
              "\\x00" + data[i]
              "\u0000" + data[i]
            ].indexOf(replies[0][i]) > -1)
            if DEBUG
              console.log "data array", [
                data[i]
                "\\x00" + data[i]
                "\u0000" + data[i]
              ]
              console.log "replies", replies
              console.log "replies[0]", replies[0], replies[0][i]
            i++
        self.emit "_intermediate", correct
        return

      if messages.length > 0
        func = (if (messages.length is 1) then callback else _intermediate)
        console.log "_txrx sending", messages[0]  if DEBUG
        self._txrx messages[0], patiences[0], func, [
          [replies[0][0]]
          [replies[0][replies[0].length - 1]]
        ]
        if func is _intermediate
          self.once "_intermediate", (correct) ->
            if correct
              self._chain messages.slice(1), patiences.slice(1), replies.slice(1), callback
            else
              self.postmaster.forceClear()
              callback new Error("Chain broke on " + messages[0]), false  if callback
            return

    return

  dial: (number, callback) ->
    if @inACall
      callback new Error("Currently in a call"), []
    else if not number or not String(number).length
      callback new Error("Did not specify a phone number"), []
    else
      @inACall = true
      @_txrx "ATD" + number + ";", 1000 * 60 * 60 * 24 * 365, (err, data) ->
        @inACall = false
        callback err, data
        return

    return

  hangUp: (callback) ->
    self = this
    @_txrx "ATH", 100000, (err, data) ->
      self.inACall = false
      callback err, data
      return

    return

  _checkEmissions: ->
    self = this
    @postmaster.on "unsolicited", (data) ->
      sent = false
      self.emissions.forEach (beginning) ->
        if data.indexOf(beginning) is 0
          self.emit beginning, data
          sent = true
        return

      self.emit "unsolicited", data  unless sent
      return

    return

  emitMe: (beginnings) ->
    self = this
    beginnings.forEach (beginning) ->
      self.emissions.push beginning
      return

    @_checkEmissions()  if @emissions.length is beginnings.length
    return

  readSMS: (index, mode, remove, callback) ->
    if typeof callback is "undefined"
      callback = remove
      remove = 0
    next = next or remove
    self = this
    @_txrx "AT+CMGR=" + index + "," + mode, 10000, (err, message) ->
      self._txrx "AT+CMGD=" + index, 10000  if remove is 1
      callback err, message
      return

    return

  sendSMS: (number, message, callback) ->
    if not number or not number.length
      callback new Error("Did not specify a phone number"), null
    else
      self = this
      message = message or "text from a Tessel"
      commands = [
        "AT+CMGF=1"
        "AT+CMGS=\"" + number + "\""
        message
      ]
      patiences = [
        2000
        5000
        5000
      ]
      replies = [
        [
          "AT+CMGF=1"
          "OK"
        ]
        [
          "AT+CMGS=\"" + number + "\""
          "> "
        ]
        [
          message
          "> "
        ]
      ]
      @_chain commands, patiences, replies, (errr, data) ->
        correct = not errr and data[0] is message and data[1] is "> "
        id = -1
        err = errr or new Error("Unable to send SMS")
        if correct
          self._txrx new Buffer([0x1a]), 10000, ((err, data) ->
            if data and data[0] and data[0].indexOf("+CMGS: ") is 0 and data[1] is "OK"
              id = parseInt(data[0].slice(7), 10)
              err = null
            callback err, [id]  if callback
            return
          ), [
            [
              "+CMGS: "
              "ERROR"
            ]
            [
              "OK"
              "ERROR"
            ]
            1
          ]
        else callback err, [id]  if callback
        return

    return

  togglePower: (callback) ->
    self = this
    debug "toggling power..."
    self.power.high()
    setTimeout (->
      self.power.low()
      setTimeout (->
        self.power.high()
        setTimeout (->
          self.emit "powerToggled"
          debug "done toggling power"
          callback()  if callback
          return
        ), 5000
        return
      ), 1500
      return
    ), 100
    return

  disable: ->
    @uart.disable()
    return

#
#  Args
#    hardware
#      The Tessel port to use for the main SIM900 hardware
#    callback
#      Callback frunction for once the module is set up
#
#    Callback parameters
#      err
#        Error, if any, while connecting. Passes null if successful.
#  
use = (hardware, callback) ->
  radio = new SIM900(hardware)
  radio._establishContact callback
  radio

debug = (thing) ->
  console.log thing  if DEBUG
  return


module.exports = SIM900
