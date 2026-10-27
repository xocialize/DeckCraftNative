<?xml version="1.0" encoding="UTF-8"?>
<!-- Markup Compatibility (ECMA-376 Part 3) as a consumer that understands only the base standard:
     every mc:AlternateContent becomes its mc:Fallback, and elements and attributes in the namespaces a
     part's mc:Ignorable lists (Office extensions) are dropped, before the part is validated. -->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006">
  <!-- The ignorable prefixes in scope, resolved to namespace URIs, space-separated with a space each side. -->
  <xsl:template name="ignored">
    <xsl:param name="node"/>
    <xsl:variable name="decl" select="$node/ancestor-or-self::*[@mc:Ignorable][1]"/>
    <xsl:call-template name="uris">
      <xsl:with-param name="ctx" select="$decl"/>
      <xsl:with-param name="list" select="concat(normalize-space($decl/@mc:Ignorable), ' ')"/>
    </xsl:call-template>
  </xsl:template>
  <xsl:template name="uris">
    <xsl:param name="ctx"/>
    <xsl:param name="list"/>
    <xsl:if test="string-length($list) &gt; 1">
      <xsl:variable name="p" select="substring-before($list, ' ')"/>
      <xsl:value-of select="concat(' ', $ctx/namespace::*[name() = $p], ' ')"/>
      <xsl:call-template name="uris">
        <xsl:with-param name="ctx" select="$ctx"/>
        <xsl:with-param name="list" select="substring-after($list, ' ')"/>
      </xsl:call-template>
    </xsl:if>
  </xsl:template>

  <xsl:template match="mc:AlternateContent">
    <xsl:apply-templates select="mc:Fallback/node()"/>
  </xsl:template>
  <xsl:template match="@mc:*"/>

  <xsl:template match="*">
    <xsl:variable name="ign"><xsl:call-template name="ignored"><xsl:with-param name="node" select="."/></xsl:call-template></xsl:variable>
    <xsl:if test="not(contains($ign, concat(' ', namespace-uri(), ' ')))">
      <xsl:copy>
        <xsl:for-each select="@*">
          <xsl:if test="namespace-uri() = '' or not(contains($ign, concat(' ', namespace-uri(), ' ')))">
            <xsl:copy-of select="."/>
          </xsl:if>
        </xsl:for-each>
        <xsl:apply-templates select="node()"/>
      </xsl:copy>
    </xsl:if>
  </xsl:template>
  <xsl:template match="@mc:Ignorable"/>
  <xsl:template match="text()|comment()|processing-instruction()"><xsl:copy/></xsl:template>
</xsl:stylesheet>
