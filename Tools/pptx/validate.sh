#!/bin/zsh
# Validate every XML part of a .pptx against the ECMA-376 5th-edition Transitional schemas with xmllint.
# A part is checked against the schema of its root element's namespace; parts in namespaces the standard
# doesn't cover (Office extensions: modern comments, chartEx, p14/p15…) are listed as skipped.
#
#   Tools/pptx/validate.sh file.pptx [more.pptx…]     prints one line per failing or skipped part
#
# Exit status: 0 when every covered part is valid, 1 otherwise. ECMA_SCHEMAS overrides the schema folder
# [../pptx-swift-main/specifications/schemas beside this repo].
set -uo pipefail

here=${0:A:h}
repo=${here:h:h}
: ${ECMA_SCHEMAS:=${repo:h}/pptx-swift-main/specifications/schemas}
xsd=$ECMA_SCHEMAS/xsd/transitional
opc=$ECMA_SCHEMAS/packaging/xsd
[[ -d $xsd ]] || { print -u2 "validate: no schemas at $xsd"; exit 2 }

typeset -A schema=(
  http://schemas.openxmlformats.org/presentationml/2006/main $xsd/pml.xsd
  http://schemas.openxmlformats.org/drawingml/2006/main $xsd/dml-main.xsd
  http://schemas.openxmlformats.org/drawingml/2006/chart $xsd/dml-chart.xsd
  http://schemas.openxmlformats.org/drawingml/2006/diagram $xsd/dml-diagram.xsd
  http://schemas.openxmlformats.org/drawingml/2006/chartDrawing $xsd/dml-chartDrawing.xsd
  http://schemas.openxmlformats.org/officeDocument/2006/extended-properties $xsd/shared-documentPropertiesExtended.xsd
  http://schemas.openxmlformats.org/officeDocument/2006/custom-properties $xsd/shared-documentPropertiesCustom.xsd
  http://schemas.openxmlformats.org/package/2006/content-types $opc/opc-contentTypes.xsd
  http://schemas.openxmlformats.org/package/2006/relationships $opc/opc-relationships.xsd
  http://schemas.openxmlformats.org/package/2006/metadata/core-properties $opc/opc-coreProperties.xsd
)

# The core-properties schema with its Dublin Core imports pointed at the local stand-ins.
work=$(mktemp -d)
trap 'rm -rf $work' EXIT
sed -e "s|http://dublincore.org/schemas/xmls/qdc/2003/04/02/dc.xsd|$here/schemas/dc.xsd|" \
    -e "s|http://dublincore.org/schemas/xmls/qdc/2003/04/02/dcterms.xsd|$here/schemas/dcterms.xsd|" \
    -e "s|<xs:import id=\"xml\" namespace=\"http://www.w3.org/XML/1998/namespace\"/>|<xs:import id=\"xml\" namespace=\"http://www.w3.org/XML/1998/namespace\" schemaLocation=\"$here/schemas/xml.xsd\"/>|" \
    $opc/opc-coreProperties.xsd > $work/opc-coreProperties.xsd
schema[http://schemas.openxmlformats.org/package/2006/metadata/core-properties]=$work/opc-coreProperties.xsd

rc=0
for pkg in "$@"; do
  tmp=$(mktemp -d)
  unzip -q -o "$pkg" -d $tmp 2> /dev/null || { print "$pkg: not a zip"; rc=1; rm -rf $tmp; continue }
  for part in $tmp/**/*.(xml|rels)(.N) $tmp/\[Content_Types\].xml(N); do
    rel=${part#$tmp/}
    # The root element's namespace: its prefix's declaration, or the default one.
    root=$(xmllint --xpath 'concat(namespace-uri(/*), "")' $part 2> /dev/null)
    s=${schema[$root]:-}
    if [[ -z $s ]]; then
      print "$pkg: $rel: skipped (namespace ${root:-none})"
      continue
    fi
    # Markup compatibility first: the part as a consumer of the base standard sees it.
    xsltproc --nonet $here/mce.xsl $part > $part.mce 2> /dev/null || cp $part $part.mce
    if ! out=$(xmllint --noout --nonet --schema $s $part.mce 2>&1); then
      print "$pkg: $rel: INVALID"
      print -r -- "$out" | grep -v ' validates$' | sed -e "s|$tmp/||" -e 's|\.mce||' | head -5 | sed 's/^/    /'
      rc=1
    fi
  done
  rm -rf $tmp
done
exit $rc
