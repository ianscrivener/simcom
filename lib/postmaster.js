(function() {
  var EventEmitter, Postmaster, util;

  util = require("util");

  EventEmitter = require("events").EventEmitter;


  /**
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
   */

  Array.prototype.softContains = function(searchStr) {
    var i;
    i = 0;
    while (i < this.length) {
      if (typeof this[i] !== "string") {
        return false;
      }
      if (searchStr.indexOf(this[i]) !== -1) {
        return true;
      }
      i++;
    }
    return false;
  };

  Postmaster = (function() {
    function Postmaster(myPacketizer, enders, overflow, size, debug) {
      var self;
      this.packetizer = myPacketizer;
      this.uart = myPacketizer.uart;
      this.RXQueue = [];
      this.callback = null;
      this.message = "";
      this.started = false;
      this.alternate = null;
      this.enders = enders || ["OK", "ERROR"];
      this.debug = debug || false;
      overflow = overflow || function(err, arg) {
        if (err) {
          console.log("err: ", err);
        } else {
          console.log("overflow!\n", arg);
        }
      };
      size = size || 15;
      self = this;
      this.packetizer.on("packet", function(data) {
        var hasCallback, hasStarted, isDataInStartArraySoft, isDataInStartArrayStrict, isUnsolicited, starts, temp, useAlternate, useSoftContains;
        hasCallback = function() {
          return self.callback !== null;
        };
        hasStarted = function() {
          return self.started;
        };
        isDataInStartArrayStrict = function() {
          if (starts.indexOf(data) === -1) {
            return false;
          } else {
            return true;
          }
        };
        isDataInStartArraySoft = function() {
          return starts.softContains(data);
        };
        isUnsolicited = function() {
          if (!hasCallback()) {
            self._debugPrint("---->>>>>>> Condition 1");
            return true;
          }
          if (!hasStarted() && !useSoftContains && !isDataInStartArrayStrict()) {
            self._debugPrint("---->>>>>>> Condition 2");
            return true;
          }
          if (!hasStarted() && useSoftContains && !isDataInStartArraySoft()) {
            self._debugPrint("---->>>>>>> Condition 3");
            return true;
          }
          return false;
        };
        starts = [self.message];
        enders = self.enders;
        useSoftContains = void 0;
        useAlternate = void 0;
        if (self.alternate) {
          starts = self.alternate[0];
          enders = self.alternate[1];
          useAlternate = true;
          useSoftContains = (self.alternate[2] ? true : false);
        } else {
          useAlternate = false;
          useSoftContains = false;
        }
        self._debugPrint("postmaster got packet: " + [data], "\nstarts:", starts, "\nenders:", enders);
        self._debugPrint("---------------");
        self._debugPrint("hasCallback", hasCallback());
        self._debugPrint("hasStarted", hasStarted());
        self._debugPrint("useSoftContains", useSoftContains);
        self._debugPrint("isDataInStartArrayStrict", isDataInStartArrayStrict());
        self._debugPrint("isDataInStartArraySoft", isDataInStartArraySoft());
        self._debugPrint("isUnsolicited", isUnsolicited());
        self._debugPrint("---------------");
        if (isUnsolicited()) {
          self._debugPrint("->>>>>>>>>> unsolicited");
          self._debugPrint(data);
          self.emit("unsolicited", data);
        } else {
          self._debugPrint("adding", [data], "to the RXQueue");
          self.started = true;
          self.RXQueue.push(data);
          console.log(enders.indexOf(data) > -1, data, enders);
          if (enders.indexOf(data) > -1) {
            self._debugPrint("\t---> Found " + data + " in enders:\n", enders, "\nEmitting a post with:\n", self.RXQueue);
            temp = self.RXQueue;
            self.RXQueue = [];
            self.started = false;
            self.alternate = null;
            self.emit("post", null, temp);
          }
        }
        if (self.RXQueue.length > size) {
          self.emit("overflow", null, self.RXQueue);
          self.RXQueue = [];
          self.started = false;
          self.alternate = null;
          self.message = "";
        }
      });
      this.on("overflow", overflow);
      return;
    }

    util.inherits(Postmaster, EventEmitter);

    Postmaster.prototype.send = function(message, patience, callback, alternate, debug) {
      var onPost, panic, reply, self;
      self = this;
      self.debug = debug || false;
      if (self.callback !== null) {
        callback(new Error("Postmaster busy"), []);
      } else {
        if (alternate) {
          self.alternate = alternate;
        }
        self.callback = callback;
        patience = patience || 10000;
        self.message = message;
        self.uart.write(message);
        self.uart.write("\r\n");
        self._debugPrint("sent", [message], "on uart", [self.uart]);
        reply = function(err, data) {
          var temp;
          temp = self.callback;
          self.callback = null;
          if (temp) {
            temp(err, data);
          }
        };
        panic = setTimeout(function() {
          var err;
          self.removeListener("post", onPost);
          err = new Error("no reply after " + patience + " ms to message \"" + message + "\"");
          err.type = "timeout";
          reply(err, []);
          self.forceClear();
        }, patience);
        onPost = function(err, data) {
          clearTimeout(panic);
          self.removeListener("post", onPost);
          self._debugPrint("postmaster replying", data);
          reply(err, data);
        };
        self.on("post", onPost);
      }
    };

    Postmaster.prototype.forceClear = function(typ) {
      var type;
      type = typ || "unsolicited";
      this.emit(type, this.RXQueue);
      this.RXQueue = [];
      this.callback = null;
      this.message = "";
      this.started = false;
      this.alternate = null;
    };

    Postmaster.prototype._debugPrint = function() {
      if (this.debug) {
        console.log(util.format.apply(util, arguments));
      }
    };

    return Postmaster;

  })();

  module.exports = Postmaster;

}).call(this);
