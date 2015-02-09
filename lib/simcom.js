(function() {
  var EventEmitter, Q, SimCom, pdu, simple_methods, util;

  util = require("util");

  Q = require("q");

  pdu = require("pdu");

  EventEmitter = require("events").EventEmitter;

  simple_methods = {
    getProductId: "ATI",
    getManufacturerId: "AT+GMI",
    getModelId: "AT+GMM",
    getImei: "AT+GSN"
  };

  SimCom = (function() {
    var handleNewMessage, handleUSSD, parse;

    function SimCom(device, options) {
      var self;
      this.isCalling = false;
      this.isRinging = false;
      this.isBusy = false;
      this.modem = require("./modem")(device, options);
      self = this;
      ["open", "close", "error", "ring", "end ring", "over-voltage warnning"].forEach(function(e) {
        self.modem.on(e, function() {
          var args;
          args = Array.prototype.slice.call(arguments);
          args.unshift(e);
          self.emit.apply(self, args);
        });
      });
      this.modem.on("new message", handleNewMessage.bind(this));
      this.modem.on("ussd", handleUSSD.bind(this));
      this.modem.open();
      return;
    }

    util.inherits(SimCom, EventEmitter);

    SimCom.prototype.close = function() {
      this.modem.close();
    };


    /**
    Execute a Raw AT Command
    @param command Raw AT Command
    @returns Promise
     */

    SimCom.prototype.execute = function(command) {
      var args;
      if (!command) {
        return;
      }
      args = Array.prototype.slice.call(arguments);
      return this.modem.execute.apply(this.modem, args);
    };

    Object.keys(simple_methods).forEach(function(name) {
      SimCom.prototype[name] = function() {
        var args, defer, self;
        self = this;
        args = Array.prototype.slice.call(arguments);
        args.unshift(simple_methods[name]);
        defer = Q.defer();
        return self.invoke.apply(self, args);
      };
    });

    parse = function(s) {
      var i, item, items, quoted, valid;
      quoted = false;
      item = "";
      items = [];
      i = 0;
      while (i < s.length) {
        valid = false;
        switch (s[i]) {
          case "\"":
            quoted = !quoted;
            break;
          case ",":
            valid = quoted;
            if (!quoted) {
              items.push(item);
              item = "";
            }
            break;
          default:
            valid = true;
        }
        if (valid) {
          item += s[i];
        }
        i++;
      }
      if (item) {
        items.push(item);
      }
      return items;
    };

    handleNewMessage = function(m) {
      m = parse(m);
      m = {
        storage: m[0],
        index: Number(m[1]),
        type: (m.length > 2 ? m[2] : "SMS")
      };
      this.emit("new message", m);
    };

    handleUSSD = function(m) {
      m = parse(m).map(function(e) {
        return e.trim();
      });
      m = {
        type: Number(m[0]),
        str: m[1],
        dcs: Number(m[2])
      };
      m.str = (m.dcs === 72 ? pdu.decode16Bit(m.str) : pdu.decode7Bit(m.str));
      this.emit("ussd", m);
    };

    SimCom.extractResponse = SimCom.prototype.extractResponse = function(resp, readPDU) {
      var cmd, cmdMatched, i, line, needPDU, pduResponse, result, tokens, _i, _len, _ref;
      if (!resp || !resp.command || !resp.lines || !resp.lines.length) {
        return;
      }
      cmd = resp.command.match(/^AT([^\=\?]*)/);
      if (!cmd || cmd.length < 2) {
        return;
      }
      cmd = cmd[1];
      result = [];
      needPDU = false;
      pduResponse = null;
      cmdMatched = false;
      i = 0;
      _ref = resp.lines;
      for (_i = 0, _len = _ref.length; _i < _len; _i++) {
        line = _ref[_i];
        if (line === "") {
          cmdMatched = false;
          continue;
        }
        if (!needPDU) {
          if (!cmdMatched) {
            if (line.substr(0, cmd.length) === cmd) {
              tokens = line.substr(cmd.length).match(/(\:\s*)*(.+)*/);
              if (tokens && tokens.length > 2) {
                line = tokens[2];
                cmdMatched = true;
              }
            }
          }
          if (line != null) {
            if (!readPDU) {
              result.push(line);
            } else {
              pduResponse = {
                response: line,
                pdu: null
              };
            }
          }
          needPDU = readPDU;
        } else {
          pduResponse.pdu = line;
          result.push(pduResponse);
          needPDU = false;
        }
      }
      return result;
    };


    /**
    Invoke a RAW AT Command, Catch and process the responses.
    @param command RAW AT Command
    @param resultReader Callback for processing the responses
    @param readPDU Try to read PDU from responses
    @returns Promise
     */

    SimCom.prototype.invoke = function(command) {
      var args, defer, readPDU, response, resultReader, self, timeout;
      defer = Q.defer();
      self = this;
      args = [].slice.apply(arguments);
      resultReader = args.length > 1 && typeof args.slice(-1)[0] === 'function' ? args.pop() : null;
      readPDU = args.length > 1 && typeof args.slice(-1)[0] === 'boolean' ? args.pop() : null;
      response = args.length > 1 && typeof args.slice(-1)[0] === 'string' ? args.pop() : null;
      timeout = args.length > 1 && typeof args.slice(-1)[0] === 'number' ? args.pop() : 5000;
      this.execute(command, timeout, function(error, res) {
        var result;
        if (error) {
          return defer.reject(error);
        }
        console.log(command, error, res);
        result = SimCom.extractResponse(res, readPDU) || null;
        if (resultReader) {
          result = resultReader.call(self, result);
        }
        defer.resolve(result);
      });
      return defer.promise;
    };

    SimCom.prototype.tryConnectOperator = function() {
      return this.invoke("AT+COPS=0", 60000, function(lines) {
        if (lines == null) {
          lines = [];
        }
        return lines.shift();
      });
    };

    SimCom.prototype.switchErrorTextMode = function() {
      return this.invoke("AT+CEER=0", function(lines) {
        if (lines == null) {
          lines = [];
        }
        return lines.shift();
      });
    };

    SimCom.prototype.getLastError = function() {
      return this.invoke("AT+CEER", function(lines) {
        if (lines == null) {
          lines = [];
        }
        return lines.shift();
      });
    };

    SimCom.prototype.getServiceProvider = function() {
      return this.invoke("AT+CSPN?", function(lines) {
        var _ref, _ref1;
        if (lines == null) {
          lines = [];
        }
        return (_ref = lines.shift()) != null ? (_ref1 = _ref.match(/"([^"]*)"/)) != null ? _ref1.pop() : void 0 : void 0;
      });
    };

    SimCom.prototype.getServiceProvider2 = function() {
      return this.invoke("AT+COPS?", function(lines) {
        var _ref, _ref1;
        if (lines == null) {
          lines = [];
        }
        return (_ref = lines.shift()) != null ? (_ref1 = _ref.match(/"([^"]*)"/)) != null ? _ref1.pop() : void 0 : void 0;
      });
    };

    SimCom.prototype.getSignalQuality = function() {
      return this.invoke("AT+CSQ", function(lines) {
        var _ref, _ref1;
        if (lines == null) {
          lines = [];
        }
        return (_ref = lines.shift()) != null ? (_ref1 = _ref.match(/(\d{1,2}),(\d)"/)) != null ? _ref1.pop() : void 0 : void 0;
      });
    };

    SimCom.prototype.getRegistrationStatus = function() {
      return this.invoke("AT+CREG?", function(lines) {
        var _ref, _ref1;
        if (lines == null) {
          lines = [];
        }
        return (_ref = lines.shift()) != null ? (_ref1 = _ref.match(/(\d{1,2}),(\d)"/)) != null ? _ref1.pop() : void 0 : void 0;
      });
    };

    SimCom.prototype.answerCall = function(callback) {
      return this.invoke("ATA", true, function(lines) {
        if (lines == null) {
          lines = [];
        }
        console.log(lines);
        return lines;
      });
    };

    SimCom.prototype.dialNumber = function(number, callback) {
      if (this.inACall) {
        return callback(new Error("Currently in a call"), []);
      } else if (!number || !String(number).length) {
        return callback(new Error("Did not specify a phone number"), []);
      } else {
        this.inACall = true;
        return this.invoke("ATD" + number + ";", function(res) {
          return callback(null, res);
        });
      }
    };

    SimCom.prototype.hangUp = function(callback) {
      var self;
      self = this;
      return this.invoke("ATH", function(lines) {
        if (lines == null) {
          lines = [];
        }
        self.inACall = false;
        return (typeof callback === "function" ? callback(lines) : void 0) || lines;
      });
    };

    SimCom.prototype.listSMS = function(stat) {
      return this.invoke("AT+CMGL=" + stat, function(res) {
        return res.map(function(m) {
          var infos;
          infos = parse(m.response);
          return {
            index: Number(infos[0]),
            stat: infos[1],
            message: pdu.parse(m.pdu)
          };
        });
      }, true);
    };

    SimCom.prototype.readSMS = function(index, peek) {
      return this.invoke(("AT+CMGR=" + index) + (peek ? 0 : 1), function(res) {
        return pdu.parse(res.shift().pdu);
      }, true);
    };

    SimCom.prototype.sendSMS = function(receiver, text) {
      var p, pduLength;
      p = pdu.generate({
        encoding: "16bit",
        receiver: receiver,
        text: text
      }).shift();
      pduLength = (p.length / 2) - 1;
      return this.invoke({
        command: "AT+CMGS=" + pduLength,
        pdu: p
      }, function(res) {
        return res.shift();
      });
    };

    SimCom.prototype.setBearerParam = function(id, tag, value) {
      return this.invoke("AT+SAPBR=3," + id + ",\"" + tag + "\",\"" + value + "\"");
    };

    SimCom.prototype.setBearerParams = function(id, params) {
      var self;
      self = this;
      return Object.keys(params).reduce(function(d, k) {
        return d.then(function() {
          self.setBearerParam(id, k, params[k]);
        });
      }, Q(0));
    };

    SimCom.prototype.getBearerParams = function(id) {
      return this.invoke("AT+SAPBR=4," + id, function(lines) {
        return lines.reduce(function(m, v) {
          v = v.split(":", 2);
          m[v[0].trim()] = v[1].trim();
          return m;
        }, {});
      });
    };

    SimCom.prototype.activateBearer = function(id) {
      return this.invoke("AT+SAPBR=1," + id);
    };

    SimCom.prototype.deactivateBearer = function(id) {
      return this.invoke("AT+SAPBR=0," + id);
    };

    SimCom.prototype.queryBearer = function(id) {
      return this.invoke("AT+SAPBR=2," + id, function(lines) {
        var cid, ip, line, m, status, status_code;
        line = lines.shift() || "";
        m = line.match(/(.+),(.+),\"([^"]*)/);
        cid = Number(m[1]);
        status_code = Number(m[2]);
        status = status_code;
        ip = m[3];
        status = (function() {
          switch (status_code) {
            case 1:
              return "connected";
            case 2:
              return "closing";
            case 3:
              return "closed";
            default:
              return "unknown";
          }
        })();
        return {
          id: cid,
          status_code: status_code,
          status: status,
          ip: ip
        };
      });
    };

    SimCom.prototype.startBearer = function(id) {
      var self;
      self = this;
      return self.queryBearer(id).then(function(res) {
        if (!res || res.status_code !== 1) {
          return self.activateBearer(id);
        }
      });
    };

    SimCom.prototype.requestUSSD = function(ussd) {
      return this.invoke("AT+CUSD=1,\"" + ussd + "\"");
    };

    return SimCom;

  })();

  module.exports = SimCom;

}).call(this);
