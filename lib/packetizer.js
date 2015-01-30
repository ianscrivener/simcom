var EventEmitter, Packetizer, checkEnd, decode, util,
  __indexOf = [].indexOf || function(item) { for (var i = 0, l = this.length; i < l; i++) { if (i in this && this[i] === item) return i; } return -1; };

util = require("util");

EventEmitter = require("events").EventEmitter;

decode = function(array) {
  var decoded, i;
  decoded = "";
  i = 0;
  while (i < array.length) {
    if (array[i] === 10 || array[i] === 13) {
      decoded += "\n";
    } else {
      decoded += String.fromCharCode(array[i]);
    }
    i++;
  }
  return decoded;
};

checkEnd = function(message, incoming, ender) {
  return (message + incoming).slice(message.length - ender.length + 1) === ender;
};

Packetizer = (function() {
  function Packetizer(uart, ender, blacklist, debug) {
    this.debug = debug || false;
    this.ender = ender || "\n";
    this.blacklist = blacklist || ["UNDER-VOLTAGE WARNNING"];
    this.messages = [];
    this.packetNumber = 0;
    this.maxBufferSize = 10;
    this.previousCharacter = "";
    this.latestMessage = "";
    this.uart = uart;
    return;
  }

  util.inherits(Packetizer, EventEmitter);

  Packetizer.prototype.getPacketCount = function() {
    return this.packetNumber;
  };

  Packetizer.prototype.bufferSize = function(len) {
    if (arguments.length > 0) {
      this.maxBufferSize = len;
    }
    return this.maxBufferSize;
  };

  Packetizer.prototype.getLatestPackets = function(num) {
    var i, packets;
    packets = [];
    i = 0;
    packets = (function() {
      var _results;
      _results = [];
      while (i < Math.min(num, this.maxBufferSize, this.messages.length)) {
        _results.push(this.messages[i++]);
      }
      return _results;
    }).call(this);
    return packets;
  };

  Packetizer.prototype.checkBlacklist = function(data) {
    return __indexOf.call(this.blacklist, data) >= 0;
  };

  Packetizer.prototype.packetize = function() {
    var self;
    self = this;
    this.uart.on("data", function(bytes) {
      var i, thing;
      i = 0;
      while (i < bytes.length) {
        thing = decode([bytes[i]]);
        if (checkEnd(self.latestMessage, thing, self.ender)) {
          if (!/^\s*$/.test(self.latestMessage + thing) && !self.checkBlacklist(self.latestMessage)) {
            if (self.debug) {
              console.log("Got a packet", self.latestMessage);
            }
            self.emit("packet", self.latestMessage);
            self.messages.push(self.latestMessage);
            self.packetNumber++;
            if (self.packetNumber > self.maxBufferSize) {
              self.emit("overflow", self.messages.shift());
            }
          }
          if (self.checkBlacklist(self.latestMessage)) {
            self.emit("blacklist", self.latestMessage);
          }
          self.latestMessage = "";
          self.previousCharacter = "";
        } else {
          self.latestMessage += thing;
          self.previousCharacter = thing;
        }
        i++;
      }
    });
  };

  return Packetizer;

})();

module.exports = Packetizer;
