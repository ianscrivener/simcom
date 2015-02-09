util = require("util")
Q = require("q")
pdu = require("pdu")
EventEmitter = require("events").EventEmitter

simple_methods =
  getProductId      : "ATI"
  getManufacturerId : "AT+GMI"
  getModelId        : "AT+GMM"
  getImei           : "AT+GSN"



class SimCom
  constructor: (device, options) ->
    @isCalling = false
    @isRinging = false
    @isBusy = false

    @modem = require("./modem")(device, options)
    self = this
    
    # delegates modem events
    [
      "open"
      "close"
      "error"
      "ring"
      "end ring"
      "over-voltage warnning"
    ].forEach (e) ->
      self.modem.on e, ->
        args = Array::slice.call(arguments)
        args.unshift e
        self.emit.apply self, args
        return

      return

    @modem.on "new message", handleNewMessage.bind(this)
    @modem.on "ussd", handleUSSD.bind(this)
    @modem.open()
    return


  util.inherits SimCom, EventEmitter

  close: ->
    @modem.close()
    return

  ###*
  Execute a Raw AT Command
  @param command Raw AT Command
  @returns Promise
  ###
  execute: (command) ->
    return  unless command
    args = Array::slice.call(arguments)
    @modem.execute.apply @modem, args

  Object.keys(simple_methods).forEach (name) ->
    SimCom::[name] = ->
      self = this
      args = Array::slice.call(arguments)
      args.unshift simple_methods[name]

      defer = Q.defer()
      self.invoke.apply(self, args)

    return

  parse = (s) ->
    quoted = false
    item = ""
    items = []
    i = 0

    while i < s.length
      valid = false
      switch s[i]
        when "\""
          quoted = not quoted
        when ","
          valid = quoted
          unless quoted
            items.push item
            item = ""
        else
          valid = true
      item += s[i]  if valid
      i++
    items.push item  if item
    items

  handleNewMessage = (m) ->
    m = parse(m)
    m =
      storage: m[0]
      index: Number(m[1])
      type: (if m.length > 2 then m[2] else "SMS")

    @emit "new message", m
    return

  handleUSSD = (m) ->
    m = parse(m).map (e) -> e.trim()
    m =
      type: Number(m[0])
      str: m[1]
      dcs: Number(m[2])

    m.str = (if m.dcs is 72 then pdu.decode16Bit(m.str) else pdu.decode7Bit(m.str))
    @emit "ussd", m
    return

  @extractResponse = @::extractResponse = (resp, readPDU) ->
    return  if not resp or not resp.command or not resp.lines or not resp.lines.length
    cmd = resp.command.match(/^AT([^\=\?]*)/)
    return  if not cmd or cmd.length < 2
    cmd = cmd[1]
    result = []
    needPDU = false
    pduResponse = null
    cmdMatched = false
    i = 0


    for line in resp.lines
      if line is ""
        cmdMatched = false
        continue

      unless needPDU
        unless cmdMatched
          if line.substr(0, cmd.length) is cmd
            tokens = line.substr(cmd.length).match(/(\:\s*)*(.+)*/)
            if tokens and tokens.length > 2
              line = tokens[2]
              cmdMatched = true
        if line?
          unless readPDU
            result.push line
          else
            pduResponse =
              response: line
              pdu: null
        needPDU = readPDU
      else
        pduResponse.pdu = line
        result.push pduResponse
        needPDU = false

    result

  ###*
  Invoke a RAW AT Command, Catch and process the responses.
  @param command RAW AT Command
  @param resultReader Callback for processing the responses
  @param readPDU Try to read PDU from responses
  @returns Promise
  ###
  invoke: (command) ->
    defer = Q.defer()
    self = this

    args = [].slice.apply arguments
    resultReader = if args.length > 1 and typeof args[-1..][0] is 'function' then args.pop() else null
    readPDU = if args.length > 1 and typeof args[-1..][0] is 'boolean' then args.pop() else null
    response = if args.length > 1 and typeof args[-1..][0] is 'string' then args.pop() else null
    timeout = if args.length > 1 and typeof args[-1..][0] is 'number' then args.pop() else 5000

    @execute command, timeout, (error, res) ->
      return defer.reject(error)  if error

      console.log command, error, res
      result = SimCom.extractResponse(res, readPDU) or null
      result = resultReader.call(self, result)  if resultReader
      defer.resolve result
      return
    defer.promise

  
  tryConnectOperator: ->
    @invoke "AT+COPS=0", 60000, (lines=[]) ->
      lines.shift()

  switchErrorTextMode: ->
    @invoke "AT+CEER=0", (lines=[]) ->
      lines.shift()


  getLastError: ->
    @invoke "AT+CEER", (lines=[]) ->
      lines.shift()

  getServiceProvider: ->
    @invoke "AT+CSPN?", (lines=[]) ->
      lines.shift()?.match(/"([^"]*)"/)?.pop()

  # TODO:
  getServiceProvider2: ->
    @invoke "AT+COPS?", (lines=[]) ->
      lines.shift()?.match(/"([^"]*)"/)?.pop()

  # TODO:
  getSignalQuality: ->
    @invoke "AT+CSQ", (lines=[]) ->
      lines.shift()?.match(/(\d{1,2}),(\d)"/)?.pop()

  # TODO:
  getRegistrationStatus: ->
    @invoke "AT+CREG?", (lines=[]) ->
      lines.shift()?.match(/(\d{1,2}),(\d)"/)?.pop()

  # TODO:
  answerCall: (callback) ->
    @invoke "ATA", true, (lines=[]) ->
      self.inACall = false
      callback?(lines) or lines


  # TODO:
  dialNumber: (number, callback) ->
    if @inACall
      callback new Error("Currently in a call"), []
    else if not number or not String(number).length
      callback new Error("Did not specify a phone number"), []
    else
      @inACall = true
      @invoke "ATD#{number};", (res) ->
        callback null, res

  # TODO:
  hangUp: (callback) ->
    self = this
    @invoke "ATH", (lines=[]) ->
      self.inACall = false
      callback?(lines) or lines

  listSMS: (stat="ALL") ->
    @invoke "AT+CMGL=#{stat}", true, (lines=[]) ->
      lines.map (m) ->
        infos = parse(m.response)
        index: Number(infos[0])
        stat: infos[1]
        message: pdu.parse(m.pdu)

  readSMS: (index, peek) ->
    @invoke "AT+CMGR=#{index}" + (if peek then 0 else 1), true, (lines=[]) ->
      pdu.parse lines.shift()?.pdu

  sendSMS: (receiver, text) ->
    p = pdu.generate(encoding: "16bit", receiver: receiver, text: text).shift()
    pduLength = (p.length / 2) - 1
    @invoke
      command: "AT+CMGS=#{pduLength}"
      pdu: p
    , (res) ->
      res.shift()

  setBearerParam: (id, tag, value) ->
    @invoke "AT+SAPBR=3,#{id},\"#{tag}\",\"#{value}\""

  setBearerParams: (id, params) ->
    self = this
    Object.keys(params).reduce (d, k) ->
      d.then ->
        self.setBearerParam id, k, params[k]
        return
    , Q(0)

  getBearerParams: (id) ->
    @invoke "AT+SAPBR=4,#{id}", (lines) ->
      lines.reduce (m, v) ->
        v = v.split(":", 2)
        m[v[0].trim()] = v[1].trim()
        m
      , {}

  activateBearer: (id) ->
    @invoke "AT+SAPBR=1,#{id}"

  deactivateBearer: (id) ->
    @invoke "AT+SAPBR=0,#{id}"

  queryBearer: (id) ->
    @invoke "AT+SAPBR=2,#{id}", (lines) ->
      line = lines.shift() or ""
      m = line.match(/(.+),(.+),\"([^"]*)/)
      cid = Number(m[1])
      status_code = Number(m[2])
      status = status_code
      ip = m[3]
      status = switch status_code
        when 1 then "connected"
        when 2 then "closing"
        when 3 then "closed"
        else "unknown"
      id: cid
      status_code: status_code
      status: status
      ip: ip

  startBearer: (id) ->
    self = this
    self.queryBearer(id).then (res) ->
      self.activateBearer id  if not res or res.status_code isnt 1

  requestUSSD: (ussd) ->
    @invoke "AT+CUSD=1,\"#{ussd}\""


module.exports = SimCom