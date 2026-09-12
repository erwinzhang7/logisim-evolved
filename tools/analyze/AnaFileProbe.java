package com.cburch.logisim.analyze.file;

import com.cburch.logisim.analyze.data.CoverColor;
import com.cburch.logisim.analyze.data.CsvInterpretor;
import com.cburch.logisim.analyze.data.CsvParameter;
import com.cburch.logisim.analyze.data.KarnaughMapGroups;
import com.cburch.logisim.analyze.gui.KarnaughMapPanel;
import com.cburch.logisim.analyze.gui.VariableTab;
import com.cburch.logisim.analyze.model.*;
import com.cburch.logisim.util.SyntaxChecker;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;

/**
 * Differential probe for the analyze <em>file and data</em> layer, feeding
 * {@code swift/Tests/LogisimAnalyzeTests/AnalyzeFileGoldenData.swift}. See
 * {@code tools/analyze/README.md} for the general recipe; this one takes the mode as
 * {@code argv[0]} and its cases on stdin:
 *
 * <pre>
 *   checkindex  one [msb..lsb] suffix per line
 *   syntax      one variable name per line
 *   csvline     one raw CSV line per line
 *   kmap        one input count per line
 *   txtsave     "&lt;inputs&gt; &lt;outputs&gt; &lt;bits&gt;", vars are name or name/width
 *   csvsave     same
 *   tex         same
 *   covers      "&lt;inputs&gt; &lt;outputs&gt; &lt;bits&gt; &lt;outputName&gt;"
 *   txtload     whole files, separated by a line reading ===
 *   csvload     same
 *   colors      no stdin
 * </pre>
 *
 * It sets {@code Main.headless = true} (D17) before anything else. Without that every error
 * path in this layer ends in {@code OptionPane} and dies with {@code HeadlessException},
 * recording nothing; with it, {@code showMessageDialog} logs to stderr and
 * {@code showConfirmDialog} returns {@code CANCEL_OPTION}, which is the same answer as the
 * Swift port's default {@code resolveInconsistentRows} closure, so the two agree by
 * construction rather than by coincidence.
 */
public class AnaFileProbe {

  static String esc(String s) {
    if (s == null) return "<null>";
    StringBuilder b = new StringBuilder();
    for (char c : s.toCharArray()) {
      if (c == '\n') b.append("\\n");
      else if (c == '\r') b.append("\\r");
      else if (c == '\t') b.append("\\t");
      else if (c == '\\') b.append("\\\\");
      else b.append(c);
    }
    return b.toString();
  }

  static AnalyzerModel model(String inSpec, String outSpec) {
    AnalyzerModel m = new AnalyzerModel();
    List<Var> in = new ArrayList<>();
    List<Var> out = new ArrayList<>();
    for (String v : inSpec.split(",")) if (!v.isEmpty()) in.add(parseVar(v));
    for (String v : outSpec.split(",")) if (!v.isEmpty()) out.add(parseVar(v));
    m.setVariables(in, out);
    return m;
  }

  static Var parseVar(String v) {
    int i = v.indexOf('/');
    if (i < 0) return new Var(v, 1);
    return new Var(v.substring(0, i), Integer.parseInt(v.substring(i + 1)));
  }

  static void fill(AnalyzerModel m, String bits) {
    TruthTable t = m.getTruthTable();
    int cols = t.getOutputColumnCount();
    int rows = t.getRowCount();
    int k = 0;
    for (int c = 0; c < cols; c++) {
      Entry[] col = new Entry[rows];
      for (int r = 0; r < rows; r++) {
        char ch = bits.charAt(k++ % bits.length());
        col[r] = ch == '1' ? Entry.ONE : ch == '0' ? Entry.ZERO : Entry.DONT_CARE;
      }
      t.setOutputColumn(c, col);
    }
  }

  public static void main(String[] args) throws Exception {
    // D17: converts every OptionPane dialog into a log line, and makes showConfirmDialog
    // return CANCEL_OPTION, which is exactly the Swift default resolveInconsistentRows.
    com.cburch.logisim.Main.headless = true;
    String mode = args[0];
    Scanner sc = new Scanner(System.in);
    switch (mode) {
      case "checkindex" -> {
        while (sc.hasNextLine()) {
          String l = sc.nextLine();
          if (l.isEmpty()) continue;
          String r;
          try { r = String.valueOf(VariableTab.checkindex(l)); }
          catch (Throwable e) { r = "EXC " + e.getClass().getSimpleName(); }
          System.out.println(esc(l) + " | " + r);
        }
      }
      case "syntax" -> {
        while (sc.hasNextLine()) {
          String l = sc.nextLine();
          String r;
          try { r = esc(SyntaxChecker.getErrorMessage(l)); }
          catch (Throwable e) { r = "EXC " + e.getClass().getSimpleName(); }
          System.out.println(esc(l) + " | " + r);
        }
      }
      case "csvline" -> {
        while (sc.hasNextLine()) {
          String l = sc.nextLine();
          List<String> f = CsvInterpretor.parseCsvLine(l, ',', '"');
          StringBuilder b = new StringBuilder();
          for (int i = 0; i < f.size(); i++) {
            if (i > 0) b.append(" ~ ");
            b.append(f.get(i) == null ? "<null>" : esc(f.get(i)));
          }
          System.out.println(esc(l) + " | " + f.size() + " | " + b);
        }
      }
      case "kmap" -> {
        while (sc.hasNextLine()) {
          String l = sc.nextLine().trim();
          if (l.isEmpty()) continue;
          int n = Integer.parseInt(l);
          int rows = 1 << KarnaughMapPanel.ROW_VARS[n];
          int cols = 1 << KarnaughMapPanel.COL_VARS[n];
          StringBuilder b = new StringBuilder();
          for (int r = 0; r < (1 << n); r++) {
            if (r > 0) b.append(",");
            b.append(KarnaughMapPanel.getRow(r, rows, cols)).append("/")
             .append(KarnaughMapPanel.getCol(r, rows, cols));
          }
          System.out.println(n + " | " + rows + " " + cols + " | " + b);
        }
      }
      case "txtsave" -> {
        while (sc.hasNextLine()) {
          String l = sc.nextLine().trim();
          if (l.isEmpty()) continue;
          String[] f = l.split("\\s+");
          AnalyzerModel m = model(f[0], f[1]);
          fill(m, f[2]);
          File tmp = File.createTempFile("anaprobe", ".txt");
          TruthtableTextFile.doSave(tmp, m);
          String s = new String(Files.readAllBytes(tmp.toPath()), StandardCharsets.UTF_8);
          StringBuilder b = new StringBuilder();
          for (String line : s.split("\n", -1)) {
            if (line.startsWith("# Exported on ")) continue;
            b.append(line).append("\n");
          }
          if (b.length() > 0) b.setLength(b.length() - 1);
          System.out.println(l + " | " + esc(b.toString()));
          tmp.delete();
        }
      }
      case "csvsave" -> {
        while (sc.hasNextLine()) {
          String l = sc.nextLine().trim();
          if (l.isEmpty()) continue;
          String[] f = l.split("\\s+");
          AnalyzerModel m = model(f[0], f[1]);
          fill(m, f[2]);
          File tmp = File.createTempFile("anaprobe", ".csv");
          TruthtableCsvFile.doSave(tmp, m);
          String s = new String(Files.readAllBytes(tmp.toPath()), StandardCharsets.UTF_8);
          System.out.println(l + " | " + esc(s));
          tmp.delete();
        }
      }
      case "txtload" -> {
        StringBuilder cur = new StringBuilder();
        List<String> blocks = new ArrayList<>();
        while (sc.hasNextLine()) {
          String l = sc.nextLine();
          if (l.equals("===")) { blocks.add(cur.toString()); cur.setLength(0); }
          else cur.append(l).append("\n");
        }
        if (cur.length() > 0) blocks.add(cur.toString());
        for (String blk : blocks) {
          File tmp = File.createTempFile("anaprobein", ".txt");
          Files.write(tmp.toPath(), blk.getBytes(StandardCharsets.UTF_8));
          AnalyzerModel m = new AnalyzerModel();
          String r;
          try {
            TruthtableTextFile.doLoad(tmp, m, null);
            r = "OK " + dump(m);
          } catch (Throwable e) {
            r = "ERR " + e.getClass().getSimpleName() + ": " + esc(e.getMessage());
          }
          System.out.println(esc(blk) + " | " + r);
          tmp.delete();
        }
      }
      case "csvload" -> {
        StringBuilder cur = new StringBuilder();
        List<String> blocks = new ArrayList<>();
        while (sc.hasNextLine()) {
          String l = sc.nextLine();
          if (l.equals("===")) { blocks.add(cur.toString()); cur.setLength(0); }
          else cur.append(l).append("\n");
        }
        if (cur.length() > 0) blocks.add(cur.toString());
        for (String blk : blocks) {
          File tmp = File.createTempFile("anaprobein", ".csv");
          Files.write(tmp.toPath(), blk.getBytes(StandardCharsets.UTF_8));
          AnalyzerModel m = new AnalyzerModel();
          String r;
          try {
            CsvParameter p = new CsvParameter();
            p.setValid();
            CsvInterpretor ci = new CsvInterpretor(tmp, p, null);
            ci.getTruthTable(m);
            r = "OK " + dump(m);
          } catch (Throwable e) {
            r = "ERR " + e.getClass().getSimpleName() + ": " + esc(e.getMessage());
          }
          System.out.println(esc(blk) + " | " + r);
          tmp.delete();
        }
      }
      case "covers" -> {
        while (sc.hasNextLine()) {
          String l = sc.nextLine().trim();
          if (l.isEmpty()) continue;
          String[] f = l.split("\\s+");
          AnalyzerModel m = model(f[0], f[1]);
          fill(m, f[2]);
          KarnaughMapGroups g = new KarnaughMapGroups(m);
          g.setOutput(f[3]);
          StringBuilder b = new StringBuilder();
          for (KarnaughMapGroups.KMapGroupInfo grp : g.getCovers()) {
            b.append("[").append(CoverColor.COVER_COLOR.getColorName(grp.getColor())).append(":");
            for (KarnaughMapGroups.CoverInfo c : grp.getAreas()) {
              b.append("(").append(c.getCol()).append(",").append(c.getRow()).append(",")
               .append(c.getWidth()).append(",").append(c.getHeight()).append(")");
            }
            b.append("]");
          }
          System.out.println(l + " | " + g.getCovers().size() + " | " + b);
        }
      }
      case "tex" -> {
        while (sc.hasNextLine()) {
          String l = sc.nextLine().trim();
          if (l.isEmpty()) continue;
          String[] f = l.split("\\s+");
          AnalyzerModel m = model(f[0], f[1]);
          fill(m, f[2]);
          File tmp = File.createTempFile("anaprobe", ".tex");
          AnalyzerTexWriter.doSave(tmp, m);
          String s = new String(Files.readAllBytes(tmp.toPath()), StandardCharsets.UTF_8);
          StringBuilder b = new StringBuilder();
          for (String line : s.split("\n", -1)) {
            if (line.startsWith("\\fancyhead[C] {")) continue;
            b.append(line).append("\n");
          }
          if (b.length() > 0) b.setLength(b.length() - 1);
          System.out.println(l + " | " + esc(b.toString()));
          tmp.delete();
        }
      }
      case "colors" -> {
        CoverColor c = CoverColor.COVER_COLOR;
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < c.nrOfColors(); i++) {
          java.awt.Color col = c.getColor(i);
          b.append(c.getColorName(col)).append("=").append(col.getRed()).append(",")
           .append(col.getGreen()).append(",").append(col.getBlue()).append(";");
        }
        System.out.println(b);
        c.reset();
        StringBuilder r = new StringBuilder();
        for (int i = 0; i < 20; i++) r.append(c.getColorName(c.getNext())).append(" ");
        System.out.println(r.toString().trim());
      }
      default -> System.out.println("unknown mode " + mode);
    }
    System.exit(0);
  }

  static String dump(AnalyzerModel m) {
    StringBuilder b = new StringBuilder();
    b.append("in=");
    for (Var v : m.getInputs().vars) b.append(v.name).append("/").append(v.width).append(",");
    b.append(" out=");
    for (Var v : m.getOutputs().vars) b.append(v.name).append("/").append(v.width).append(",");
    TruthTable t = m.getTruthTable();
    b.append(" rows=").append(t.getVisibleRowCount()).append(" ");
    for (int r = 0; r < t.getVisibleRowCount(); r++) {
      for (int c = 0; c < t.getInputColumnCount(); c++) b.append(t.getVisibleInputEntry(r, c).getDescription());
      b.append(":");
      for (int c = 0; c < t.getOutputColumnCount(); c++) b.append(t.getVisibleOutputEntry(r, c).getDescription());
      b.append(" ");
    }
    return b.toString().trim();
  }
}
