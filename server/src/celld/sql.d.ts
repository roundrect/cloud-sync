// celld.jsonc's `rules` import every *.sql file as its text.
declare module "*.sql" {
  const text: string;
  export default text;
}
