      var mathStore = [];

      function protectMath(md) {
        mathStore = [];
        var n = md.length;
        var inCode = new Array(n);
        var pos = 0;
        var fenced = false, fenceCh = '', fenceLen = 0;
        var lines = md.split('\n');
        for (var k = 0; k < lines.length; k++) {
          var line = lines[k];
          var t = line.replace(/^[ \t]+/, '');
          if (fenced) {
            for (var q = pos; q < pos + line.length; q++) inCode[q] = true;
            var cm = t.match(/^(`{3,}|~{3,})[ \t]*$/);
            if (cm && cm[1].charAt(0) === fenceCh && cm[1].length >= fenceLen) {
              fenced = false;
              for (var q2 = pos; q2 < pos + line.length; q2++) inCode[q2] = false;
            }
          } else {
            var fm = t.match(/^(`{3,}|~{3,})/);
            if (fm) {
              fenced = true;
              fenceCh = fm[1].charAt(0);
              fenceLen = fm[1].length;
              for (var q3 = pos; q3 < pos + line.length; q3++) inCode[q3] = true;
            }
          }
          pos += line.length + 1;
        }
        var out = '';
        var i = 0;
        while (i < n) {
          if (inCode[i]) { out += md.charAt(i); i++; continue; }
          if (md.charAt(i) === '`') {
            var j = i;
            while (j < n && md.charAt(j) === '`') j++;
            var run = md.slice(i, j);
            var end = md.indexOf(run, j);
            if (end === -1) { out += run; i = j; continue; }
            out += md.slice(i, end + run.length);
            i = end + run.length;
            continue;
          }
          var m = null;
          if (md.slice(i, i + 2) === '$$') {
            m = /^\$\$([\s\S]*?)\$\$/.exec(md.slice(i));
          } else if (md.slice(i, i + 2) === '\\[') {
            m = /^\\\[([\s\S]*?)\\\]/.exec(md.slice(i));
          } else if (md.slice(i, i + 2) === '\\(') {
            m = /^\\\(([\s\S]*?)\\\)/.exec(md.slice(i));
          } else if (md.charAt(i) === '$') {
            m = /^\$(\S(?:[^$\n]*\S)?)\$/.exec(md.slice(i));
          }
          if (m) {
            out += '%%MATH' + mathStore.length + '%%';
            mathStore.push(m[0]);
            i += m[0].length;
          } else {
            out += md.charAt(i);
            i++;
          }
        }
        return out;
      }

      function restoreMath(html) {
        return html.replace(/%%MATH(\d+)%%/g, function (all, d) {
          var seg = mathStore[Number(d)];
          return seg === undefined ? all : escapeHtml(seg);
        });
      }
