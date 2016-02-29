util = require("util")
Q = require("q")
pdu = require("pdu")
EventEmitter = require("events").EventEmitter

simple_methods =
  getProductID      : "ATI"
  getManufacturerID : "AT+GMI"
  getModelID        : "AT+GMM"
  getIMEI           : "AT+GSN"



class SimCom
  constructor: (device, options) ->
    @isCalling = false
    @isRinging = false
    @isBusy = false

    @modem = require("./modem")(device, options)

    # delegates modem events
    [
      "open"
      "close"
      "error"
      "ring"
      "end ring"
      "end call"
      "over-voltage warnning"
    ].forEach (e) =>
      @modem.on e, (args...) =>
        args.unshift e
        @emit.apply this, args
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

  # Object.keys(simple_methods).forEach (name) ->
  #   SimCom::[name] = ->
  #     self = this
  #     args = Array::slice.call(arguments)
  #     args.unshift simple_methods[name]

  #     defer = Q.defer()
  #     self.invoke.apply(self, args)

  #   return

  date = (s) ->
    s = String(s).replace /^(\d{2})\/(\d{2})\/(\d{2})\,(\d{2})\:(\d{2})\:(\d{2})\+(\d{2})$/, (m...) ->
      "20#{m[1]}-#{m[2]}-#{m[3]}T#{m[4]}:#{m[5]}:#{m[6]}+0#{(m[7]/4)}00"
    new Date s

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
    self = this
    m = parse(m).map (e) -> e.trim()
    m =
      storage: m[0]
      index: Number(m[1])
      type: (if m.length > 2 then m[2] else "SMS")

    @readSMS(m.index).done (res) -> self.emit "new message", res, m

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
  invoke: (command, args...) ->
    return   unless command?
    defer = Q.defer()
    self = this

    resultReader = if typeof args[-1..][0] is 'function' then args.pop() else null
    readPDU = if typeof args[-1..][0] in ['boolean','object'] then args.pop() else false
    response = if typeof args[-1..][0] is 'string' then args.pop() else null
    timeout = if typeof args[-1..][0] is 'number' then args.pop() else null

    @execute command, timeout, response, readPDU, (error, res) ->
      return defer.reject(error)  if error

      result = SimCom.extractResponse(res, readPDU) or null
      result = resultReader.call(self, result)  if resultReader
      result = if Array.isArray result and result.length is 1 then result.shift() else result
      defer.resolve result
      return
    defer.promise


  init: ->
    # Reset to factory defaults
    @execute "AT&F", 1000, 'OK'

    # Set Mobile Equipment Error Code
    @execute "AT+CMEE=0", 500, 'OK'

    # Set error text-mode
    @execute "AT+CEER=0", 500, 'OK'

    # Set volume
    @execute "AT+CLVL=100", 1000, 'OK'

    # Enable Called ID casting
    @execute "AT+CLIP=1", 500, 'OK'

    # Set call presentation
    @execute "AT+COLP=1", 500, 'OK'

    # Set the SMS mode to text
    @execute "AT+CMGF=1", 500, 'OK'

    # Select operator
    @execute "AT+COPS=0", 60000, 'OK'

    # Register network
    @execute "AT+CREG=1", 2000, 'OK'

    # Setup SMS memory
    @execute "AT+CNMI=2,0", 2000, 'OK'
    @execute "AT+CPMS=\"SM\",\"SM\",\"SM\"", 2000
    @execute "AT+CPBS=\"SM\"", 1000, 'OK'

    @getLastError()

  # Reset to the factory settings
  setFactoryDefaults: ->
    @execute "AT&F", 10000, 'OK'

  # switch off echo
  setEchoOff: ->
    @execute "ATE0", 2000, 'OK'

  # set volume
  setVolume: (level=5) ->
    @execute "AT+CLVL=#{level}", 2000, 'OK'

  # set the SMS mode to text
  setSmsTextMode: ->
    @execute "AT+CMGF=1", 2000, 'OK'

  setErrorTextMode: ->
    @execute "AT+CEER=0", 2000, 'OK'

  setCallPresentation: ->
    @execute "AT+COLP=1", 2000, 'OK'

  setCallIdentification: ->
    @execute "AT+CLIP=1", 2000, 'OK'

  getLastError: ->
    @invoke "AT+CEER", (lines=[]) ->
      "test=" + lines.shift()

  getProductID: ->
    @invoke "ATI", (lines=[]) ->
      lines.shift()

  getManufacturerID: ->
    @invoke "AT+GMI", (lines=[]) ->
      lines.shift()

  getModelID: ->
    @invoke "AT+GMM", (lines=[]) ->
      lines.shift()

  getIMEI: ->
    @invoke "AT+GSN", (lines=[]) ->
      lines.shift()

  getServiceProvider: ->
    @invoke "AT+CSPN?", (lines=[]) ->
      lines.shift()?.match(/"([^"]*)"/)?.pop()

  getSignalQuality: ->
    @invoke "AT+CSQ", (lines=[]) ->
      signal = lines.shift()?.match(/(\d+),(\d+)/)?[1]
      signal = parseInt(signal)
      signalWord = switch
        when signal < 10 then "marginal"
        when signal < 15 then "ok"
        when signal < 20 then "good"
        when signal < 30 then "excellent"
        else "unknown"

      signal = -1 * (113 - (signal*2))
      [signal, signalWord]

  getRegistrationStatus: ->
    statuses = [
      "not registered"
      "registered, home network"
      "searching"
      "registration denied"
      "unknown"
      "registered, roaming"
      "registered, sms only, home network"
      "registered, sms only, roaming"
      "emergency services only"
      "registered, csfb not preferred, home network"
      "registered, csfb not preferred, roaming"
    ]

    @invoke "AT+CREG?", (lines=[]) ->
      status = lines.shift()?.match(/(\d+),(\d+)/)?[1]
      statuses[status]


  getPhoneNumber: ->
    @invoke "AT+CNUM", (lines=[]) ->
      lines.shift()?.match(/,"([^"]*)"/)?.pop()

  # TODO:
  answerCall: (callback) ->
    self = this
    @invoke "ATA", true, (lines=[]) ->
      self.isCalling = false
      callback?(lines) or lines


  # TODO:
  dialNumber: (number, callback) ->
    self = this

    if @modem.isCalling
      callback new Error("Currently in a call"), null
    else if not number or not String(number).length
      callback new Error("Did not specified a phone number"), null
    else
      @modem.isCalling = true
      @execute "ATD#{number};", 5000, 'OK', (err, res) ->
        self.modem.isCalling = false  if err?
        callback err, res
        return
    return

  # TODO:
  hangUp: (callback) ->
    self = this
    @execute "ATH", 'OK', (err, res) ->
      if not err and res.success
        self.modem.isCalling = false
        self.modem.isRinging = false
      callback err, res
    return

  listSMS: (stat="ALL") ->
    @invoke "AT+CMGL=\"#{stat}\"", true, (lines=[]) ->
      lines.map (m) ->
        infos = parse(m.response)
        index: Number(infos[0])
        stat: infos[1]
        from: infos[2]
        time: date infos[4]
        message: m.pdu

  readSMS: (index) ->
    @invoke "AT+CMGR=#{index}", true, (lines=[]) ->
      result = lines.shift()
      message = result.pdu
      m = parse(result.response)

      {
        index: Number(index)
        stat: m[0]
        from: m[1]
        time: date m[3]
        message: message
      }

  deleteSMS: (index, callback) ->
    @invoke "AT+CMGD=#{index}", 10000, 'OK', true, callback

  deleteAllSMS: (callback) ->
    @invoke "AT+CMGD=0,4", 30000, 'OK', true, callback

  sendSMS: (number, message='ping!', callback) ->
    @execute "AT+CMGS=\"#{number}\"\r#{message}", 10000, callback

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
