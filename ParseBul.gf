--# -path=.:../abstract:../common
concrete ParseBul of Parse =
  NounBul,
  VerbBul - [PassV2],
  AdjectiveBul,
  AdverbBul,
  NumeralBul,
  SentenceBul,
  QuestionBul,
  RelativeBul,
  ConjunctionBul,
  PhraseBul,
  TextBul,
  IdiomBul,
  TenseX - [CAdv,IAdv,SC],
  ParseExtendBul,
  WordNetBul,
  DocumentationBul
  ** open MorphoBul, ResBul, (S = StructuralBul), (L = LexiconBul), (E = ExtendBul), ParadigmsBul, Prelude in {

-- INJECT

} ;
