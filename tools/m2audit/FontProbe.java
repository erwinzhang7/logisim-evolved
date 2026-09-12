// `Attributes.FontAttribute` round-trip, run on the JDK the oracle runs on.
//
//   parse            -> Font.decode(value)
//   toStandardString -> "%s %s %s" of getFamily(), style, size      (Attributes.java:184-196)
//
// The question the migration gate raises: what does `getFamily()` return for a family that is
// not installed? If AWT substitutes and reports the substitute, the oracle rewrites the font
// name on every save and a port that preserves the requested name cannot match it.
//
// Build: javac -d out FontProbe.java
// Run:   java -Djava.awt.headless=true -cp out FontProbe "Ubuntu Sans Mono bold 18" ...

import java.awt.Font;

public final class FontProbe {
  public static void main(String[] args) {
    if (args.length == 0) {
      System.err.println("usage: FontProbe <font-string> ...");
      System.exit(2);
    }
    int emitted = 0;
    for (final String value : args) {
      final Font font = Font.decode(value);
      final String style =
          switch (font.getStyle()) {
            case Font.PLAIN -> "plain";
            case Font.BOLD -> "bold";
            case Font.ITALIC -> "italic";
            default -> "bolditalic";
          };
      System.out.println(
          value
              + "\tname="
              + font.getName()
              + "\tfamily="
              + font.getFamily()
              + "\tstandard="
              + String.format("%s %s %s", font.getFamily(), style, font.getSize()));
      emitted++;
    }
    if (emitted == 0) {
      System.err.println("FontProbe produced no output");
      System.exit(3);
    }
  }
}
