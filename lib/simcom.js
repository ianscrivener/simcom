(function() {
  var EventEmitter, Q, SimCom, pdu, simple_methods, util,
    slice = [].slice;

  util = require("util");

  Q = require("q");

  pdu = require("pdu");

  EventEmitter = require("events").EventEmitter;

  simple_methods = {
    getProductID: "ATI",
    getManufacturerID: "AT+GMI",
    getModelID: "AT+GMM",
    getIMEI: "AT+GSN"
  };

  SimCom = (function() {
    var date, handleNewMessage, handleUSSD, parse;

    function SimCom(device, options) {
      this.isCalling = false;
      this.isRinging = false;
      this.isBusy = false;
      this.modem = require("./modem")(device, options);
      ["open", "close", "error", "ring", "end ring", "end call", "over-voltage warnning"].forEach((function(_this) {
        return function(e) {
          _this.modem.on(e, function() {
            var args;
            args = 1 <= arguments.length ? slice.call(arguments, 0) : [];
            args.unshift(e);
            _this.emit.apply(_this, args);
          });
        };
      })(this));
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

    date = function(s) {
      s = String(s).replace(/^(\d{2})\/(\d{2})\/(\d{2})\,(\d{2})\:(\d{2})\:(\d{2})\+(\d{2})$/, function() {
        var m;
        m = 1 <= arguments.length ? slice.call(arguments, 0) : [];
        return "20" + m[1] + "-" + m[2] + "-" + m[3] + "T" + m[4] + ":" + m[5] + ":" + m[6] + "+0" + (m[7] / 4) + "00";
      });
      return new Date(s);
    };

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
      var self;
      self = this;
      m = parse(m).map(function(e) {
        return e.trim();
      });
      m = {
        storage: m[0],
        index: Number(m[1]),
        type: (m.length > 2 ? m[2] : "SMS")
      };
      this.readSMS(m.index).done(function(res) {
        return self.emit("new message", res, m);
      });
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
      var cmd, cmdMatched, i, j, len, line, needPDU, pduResponse, ref, result, tokens;
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
      ref = resp.lines;
      for (j = 0, len = ref.length; j < len; j++) {
        line = ref[j];
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

    SimCom.prototype.invoke = function() {
      var args, command, defer, readPDU, ref, response, resultReader, self, timeout;
      command = arguments[0], args = 2 <= arguments.length ? slice.call(arguments, 1) : [];
      if (command == null) {
        return;
      }
      defer = Q.defer();
      self = this;
      resultReader = typeof args.slice(-1)[0] === 'function' ? args.pop() : null;
      readPDU = (ref = typeof args.slice(-1)[0]) === 'boolean' || ref === 'object' ? args.pop() : false;
      response = typeof args.slice(-1)[0] === 'string' ? args.pop() : null;
      timeout = typeof args.slice(-1)[0] === 'number' ? args.pop() : null;
      this.execute(command, timeout, response, readPDU, function(error, res) {
        var result;
        if (error) {
          return defer.reject(error);
        }
        result = SimCom.extractResponse(res, readPDU) || null;
        if (resultReader) {
          result = resultReader.call(self, result);
        }
        result = Array.isArray(result && result.length === 1) ? result.shift() : result;
        defer.resolve(result);
      });
      return defer.promise;
    };

    SimCom.prototype.init = function() {
      this.execute("AT&F", 1000, 'OK');
      this.execute("AT+CMEE=0", 500, 'OK');
      this.execute("AT+CEER=0", 500, 'OK');
      this.execute("AT+CLVL=100", 1000, 'OK');
      this.execute("AT+CLIP=1", 500, 'OK');
      this.execute("AT+COLP=1", 500, 'OK');
      this.execute("AT+CMGF=1", 500, 'OK');
      this.execute("AT+COPS=0", 60000, 'OK');
      this.execute("AT+CREG=1", 2000, 'OK');
      this.execute("AT+CNMI=2,0", 2000, 'OK');
      this.execute("AT+CPMS=\"SM\",\"SM\",\"SM\"", 2000);
      this.execute("AT+CPBS=\"SM\"", 1000, 'OK');
      return this.getLastError();
    };

    SimCom.prototype.setFactoryDefaults = function() {
      return this.execute("AT&F", 10000, 'OK');
    };

    SimCom.prototype.setEchoOff = function() {
      return this.execute("ATE0", 2000, 'OK');
    };

    SimCom.prototype.setVolume = function(level) {
      if (level == null) {
        level = 5;
      }
      return this.execute("AT+CLVL=" + level, 2000, 'OK');
    };

    SimCom.prototype.setSmsTextMode = function() {
      return this.execute("AT+CMGF=1", 2000, 'OK');
    };

    SimCom.prototype.setErrorTextMode = function() {
      return this.execute("AT+CEER=0", 2000, 'OK');
    };

    SimCom.prototype.setCallPresentation = function() {
      return this.execute("AT+COLP=1", 2000, 'OK');
    };

    SimCom.prototype.setCallIdentification = function() {
      return this.execute("AT+CLIP=1", 2000, 'OK');
    };

    SimCom.prototype.getLastError = function() {
      return this.invoke("AT+CEER", function(lines) {
        if (lines == null) {
          lines = [];
        }
        return "test=" + lines.shift();
      });
    };

    SimCom.prototype.getProductID = function() {
      return this.invoke("ATI", function(lines) {
        if (lines == null) {
          lines = [];
        }
        return lines.shift();
      });
    };

    SimCom.prototype.getManufacturerID = function() {
      return this.invoke("AT+GMI", function(lines) {
        if (lines == null) {
          lines = [];
        }
        return lines.shift();
      });
    };

    SimCom.prototype.getModelID = function() {
      return this.invoke("AT+GMM", function(lines) {
        if (lines == null) {
          lines = [];
        }
        return lines.shift();
      });
    };

    SimCom.prototype.getIMEI = function() {
      return this.invoke("AT+GSN", function(lines) {
        if (lines == null) {
          lines = [];
        }
        return lines.shift();
      });
    };

    SimCom.prototype.getServiceProvider = function() {
      return this.invoke("AT+CSPN?", function(lines) {
        var ref, ref1;
        if (lines == null) {
          lines = [];
        }
        return (ref = lines.shift()) != null ? (ref1 = ref.match(/"([^"]*)"/)) != null ? ref1.pop() : void 0 : void 0;
      });
    };

    SimCom.prototype.getSignalQuality = function() {
      return this.invoke("AT+CSQ", function(lines) {
        var ref, ref1, signal, signalWord;
        if (lines == null) {
          lines = [];
        }
        signal = (ref = lines.shift()) != null ? (ref1 = ref.match(/(\d+),(\d+)/)) != null ? ref1[1] : void 0 : void 0;
        signal = parseInt(signal);
        signalWord = (function() {
          switch (false) {
            case !(signal < 10):
              return "marginal";
            case !(signal < 15):
              return "ok";
            case !(signal < 20):
              return "good";
            case !(signal < 30):
              return "excellent";
            default:
              return "unknown";
          }
        })();
        signal = -1 * (113 - (signal * 2));
        return [signal, signalWord];
      });
    };

    SimCom.prototype.getRegistrationStatus = function() {
      var statuses;
      statuses = ["not registered", "registered, home network", "searching", "registration denied", "unknown", "registered, roaming", "registered, sms only, home network", "registered, sms only, roaming", "emergency services only", "registered, csfb not preferred, home network", "registered, csfb not preferred, roaming"];
      return this.invoke("AT+CREG?", function(lines) {
        var ref, ref1, status;
        if (lines == null) {
          lines = [];
        }
        status = (ref = lines.shift()) != null ? (ref1 = ref.match(/(\d+),(\d+)/)) != null ? ref1[1] : void 0 : void 0;
        return statuses[status];
      });
    };

    SimCom.prototype.getPhoneNumber = function() {
      return this.invoke("AT+CNUM", function(lines) {
        var ref, ref1;
        if (lines == null) {
          lines = [];
        }
        return (ref = lines.shift()) != null ? (ref1 = ref.match(/,"([^"]*)"/)) != null ? ref1.pop() : void 0 : void 0;
      });
    };

    SimCom.prototype.answerCall = function(callback) {
      var self;
      self = this;
      return this.invoke("ATA", true, function(lines) {
        if (lines == null) {
          lines = [];
        }
        self.isCalling = false;
        return (typeof callback === "function" ? callback(lines) : void 0) || lines;
      });
    };

    SimCom.prototype.dialNumber = function(number, callback) {
      var self;
      self = this;
      if (this.modem.isCalling) {
        callback(new Error("Currently in a call"), null);
      } else if (!number || !String(number).length) {
        callback(new Error("Did not specified a phone number"), null);
      } else {
        this.modem.isCalling = true;
        this.execute("ATD" + number + ";", 5000, 'OK', function(err, res) {
          if (err != null) {
            self.modem.isCalling = false;
          }
          callback(err, res);
        });
      }
    };

    SimCom.prototype.hangUp = function(callback) {
      var self;
      self = this;
      this.execute("ATH", 'OK', function(err, res) {
        if (!err && res.success) {
          self.modem.isCalling = false;
          self.modem.isRinging = false;
        }
        return callback(err, res);
      });
    };

    SimCom.prototype.listSMS = function(stat) {
      if (stat == null) {
        stat = "ALL";
      }
      return this.invoke("AT+CMGL=\"" + stat + "\"", true, function(lines) {
        if (lines == null) {
          lines = [];
        }
        return lines.map(function(m) {
          var infos;
          infos = parse(m.response);
          return {
            index: Number(infos[0]),
            stat: infos[1],
            from: infos[2],
            time: date(infos[4]),
            message: m.pdu
          };
        });
      });
    };

    SimCom.prototype.readSMS = function(index) {
      return this.invoke("AT+CMGR=" + index, true, function(lines) {
        var m, message, result;
        if (lines == null) {
          lines = [];
        }
        result = lines.shift();
        message = result.pdu;
        m = parse(result.response);
        return {
          index: Number(index),
          stat: m[0],
          from: m[1],
          time: date(m[3]),
          message: message
        };
      });
    };

    SimCom.prototype.deleteSMS = function(index, callback) {
      return this.invoke("AT+CMGD=" + index, 10000, 'OK', true, callback);
    };

    SimCom.prototype.deleteAllSMS = function(callback) {
      return this.invoke("AT+CMGD=0,4", 30000, 'OK', true, callback);
    };

    SimCom.prototype.sendSMS = function(number, message, callback) {
      if (message == null) {
        message = 'ping!';
      }
      return this.execute("AT+CMGS=\"" + number + "\"\r" + message, 10000, callback);
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
